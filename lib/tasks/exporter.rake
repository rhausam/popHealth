require 'hqmf-parser'

namespace :export do
  desc 'Generate QRDA CAT1 files for all patients, then copy them into sub-folders by HQMF_ID where each patient is part of the IPP for that measure.'
  task :cat1 do
    puts "Rails env: #{Rails.env}"
    exporter = HealthDataStandards::Export::Cat1.new
    mongo_session = Mongoid.session(:default)

    # Collect list of HQMF IDs
    measures = []
    hqmf_ids = HealthDataStandards::CQM::Measure.all.collect{|m| m.hqmf_id }.uniq
    puts "Parsing HQMF documents"

    hqmf_ids.each_with_index do |hqmf_id, index|
      puts "#{index+1} of #{hqmf_ids.length}: #{hqmf_id}"

      mongo_session['measures'].find({ hqmf_id: hqmf_id }).each do |measure|
        measures << HQMF::Document.from_json(measure['hqmf_document'])
      end
    end

    # Load PatientCacheValue objects that contain the data that matches a patient
    # to an IPP on a measure
    puts "\nLoading #{mongo_session['patient_cache'].find.count} patient cache objects..."
    patient_cache_values = mongo_session['patient_cache'].find.collect{|pc| pc['value'] }

    # Clear out previous export files
    base_cat1_dir = File.join(Rails.root, 'tmp', 'cat1-exports')
    FileUtils.rm_rf(File.join(base_cat1_dir))

    # Spit out the resulting CAT1 files, per patient, per measure, per IPP
    puts "\nExporting CAT1 by HQMF set_id"
    all_patient_records = Record.all
    all_patient_records.each do |patient|
      puts "Patient: #{patient.last}, #{patient.first}"
      measures.each do |measure|
        nqf_id = measure.attributes.select{|attr| attr.id == "NQF_ID_NUMBER" }.first.value
        per_measure_dir = File.join(base_cat1_dir, "#{nqf_id}-#{measure.hqmf_set_id}")

        pcvs_where_patient_is_in_ipp = patient_cache_values.select do |pcv|
          pcv['IPP'] == 1 &&
          pcv['medical_record_id'] == patient.medical_record_number &&
          measure.hqmf_id == pcv['measure_id']
        end
        pcvs_where_patient_is_in_ipp.uniq!

        if pcvs_where_patient_is_in_ipp.size > 0
          FileUtils.mkdir_p(per_measure_dir)
        end

        pcvs_where_patient_is_in_ipp.each_with_index do |pcv, index|
          export_filename = "#{per_measure_dir}/#{index.to_s.rjust(3, '0')}-#{nqf_id}-#{patient.last.downcase}-#{patient.first.downcase}.cat1.xml"
          puts "  Generating #{export_filename.split('/').last(2).split('/').last(2).join('/')}"

          output = File.open(export_filename, "w")
          output << exporter.export(patient, [measure], Time.gm(2012,1,1, 23,59,00), Time.gm(2012,12,31, 23,59,00),)
          output.close
        end
      end
    end
  end


  desc 'Generate QRDA3 file for specified measures (NQF_ID=0004,0038) or measure types (MEASURE_TYPE=[ep|eh])'
  task :cat3 do
    exporter = HealthDataStandards::Export::Cat3.new
    measures = []
    if ENV['NQF_ID']
      measures = HealthDataStandards::CQM::Measure.any_in({nqf_id: ENV['NQF_ID'].split(",")}).sort(nqf_id: 1, sub_id: 1)
    elsif ENV['MEASURE_TYPE']
      measures = case ENV['MEASURE_TYPE']
        when "ep" then HealthDataStandards::CQM::Measure.all.where(type: "ep").sort(nqf_id: 1, sub_id: 1)
        when "eh" then HealthDataStandards::CQM::Measure.all.where(type: "eh").sort(nqf_id: 1, sub_id: 1)
        else           HealthDataStandards::CQM::Measure.sort(nqf_id: 1, sub_id: 1)
      end
    else
      choose do |menu|
        menu.prompt = "Which measures? "
        HealthDataStandards::CQM::Measure.all.group_by(&:nqf_id).sort.each do |nqf_id, ms|
          menu.choice(nqf_id){ measures = ms }
        end
        menu.choice(:q, "quit") { say "quitter"; exit }
      end
    end
    effective_date = Time.gm(2012, 12, 31,23,59,00)
    measures.each do |measure|
      measure_model = QME::QualityMeasure.new(measure['id'], measure['sub_id'])
      oid_dictionary = OidHelper.generate_oid_dictionary(measure_model.definition)
      qr = QME::QualityReport.new(measure['id'],
                                  measure['sub_id'],
                                  'effective_date' => effective_date.to_i,
                                  'test_id' => measure['test_id'],
                                  'oid_dictionary' => oid_dictionary)
      qr.calculate(false) unless qr.calculated?
    end
    destination_dir = File.join(Rails.root, 'tmp', 'test_results')
    FileUtils.mkdir_p destination_dir
    puts "Measures: " + measures.map{|m| "#{m.nqf_id}#{m.sub_id}"}.join(",")
    puts "Rails env: #{Rails.env}"
    puts "Exporting #{destination_dir}/#{Time.now.strftime '%Y-%m-%d_%H%M'}.cat3.xml..."
    output = File.open(File.join(destination_dir, "#{Time.now.strftime '%Y-%m-%d_%H%M'}.cat3.xml"), "w")
    output << exporter.export(measures, generate_header(Time.now), effective_date, Date.parse("2012-01-01"), Date.parse("2012-12-31"))
    output.close
  end

  def generate_header(time)
    Qrda::Header.new(YAML.load(File.read(File.join(Rails.root, 'config', 'qrda3_header.yml'))).deep_merge(legal_authenticator: {time: time}), authors: {time: time})
  end
end
