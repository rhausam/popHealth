require 'hqmf-parser'

namespace :export_20140701_20140930 do
  desc 'Generate QRDA CAT1 files for all patients, then copy them into sub-folders by HQMF_ID where each patient is part of the IPP for that measure.'
  task :cat1 do
    puts "Rails env: #{Rails.env}"
    exporter = HealthDataStandards::Export::Cat1.new
    mongo_session = Mongoid.session(:default)

    unless ENV['NQF_ID']
      puts "You must specify an NQF_ID"
      next
    end

    puts "NQF_ID #{ENV['NQF_ID']}"
    cqm_measures = HealthDataStandards::CQM::Measure.all.select{|m| m.nqf_id == ENV['NQF_ID']}

    hqmf_docs = []

    puts "Parsing HQMF documents"
    cqm_measures.each_with_index do |cqm_measure, index|
      mongo_session['measures'].find({ hqmf_id: cqm_measure.hqmf_id }).each do |mongo_measure|
        puts "#{index+1} of #{cqm_measures.length}: HQMF / SET / NQF :: #{mongo_measure['hqmf_id']} / #{mongo_measure['hqmf_set_id']} / #{mongo_measure['nqf_id']}"
        hqmf_docs << HQMF::Document.from_json(cqm_measure['hqmf_document'])
      end
    end

    puts "Building patient caches..."
    effective_date = Time.gm(2014, 12, 31,23,59,00)
    cqm_measures.each_with_index do |cqm_measure, index|
      puts "#{index+1} of #{cqm_measures.size}: #{cqm_measure.title}"
      measure_model = QME::QualityMeasure.new(cqm_measure['id'], cqm_measure['sub_id'])
      oid_dictionary = OidHelper.generate_oid_dictionary(measure_model.definition)
      qr = QME::QualityReport.new(cqm_measure['id'],
                                  cqm_measure['sub_id'],
                                  'effective_date' => effective_date.to_i,
                                  'test_id' => cqm_measure['test_id'],
                                  'oid_dictionary' => oid_dictionary)
      qr.calculate(false) unless qr.calculated?
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
    all_patient_records.each_with_index do |patient, index|
      puts "Patient: #{index+1} of #{all_patient_records.size} #{patient.last}, #{patient.first}"
      hqmf_docs.each do |hqmf_doc|
        nqf_id = hqmf_doc.attributes.select{|attr| attr.id == "NQF_ID_NUMBER" }.first.value
        per_measure_dir = File.join(base_cat1_dir, "#{nqf_id}-#{hqmf_doc.hqmf_set_id}")

        pcvs_where_patient_is_in_ipp = patient_cache_values.select do |pcv|
          pcv['IPP'] == 1 &&
          pcv['medical_record_id'] == patient.medical_record_number &&
          hqmf_doc.hqmf_id == pcv['measure_id']
        end
        pcvs_where_patient_is_in_ipp.uniq!

        if pcvs_where_patient_is_in_ipp.size > 0
          FileUtils.mkdir_p(per_measure_dir)
        end

        pcvs_where_patient_is_in_ipp.each_with_index do |pcv, index|
          export_filename = "#{per_measure_dir}/#{index.to_s.rjust(3, '0')}-#{pcv['nqf_id']}-#{patient.last.downcase}-#{patient.first.downcase}.cat1.xml"
          puts "  Generating #{export_filename.split('/').last(2).split('/').last(2).join('/')}"

          output = File.open(export_filename, "w")
          output << exporter.export(patient, [hqmf_doc], Time.gm(2014,1,1, 23,59,00), Time.gm(2014,12,31, 23,59,00),)
          output.close
        end
      end
    end
  end


  desc 'Generate QRDA3 file for specified measures (NQF_ID=0004,0038) or measure types (MEASURE_TYPE=[ep|eh])'
  task :cat3 do
    exporter = HealthDataStandards::Export::Cat3.new
    measures = []
    filename = %{#{Time.now.strftime '%Y-%m-%d_%H%M'}.cat3.xml}
    if ENV['SUB_ID'] && ENV['NQF_ID']
      measures = HealthDataStandards::CQM::Measure.where({nqf_id: ENV['NQF_ID'], sub_id: ENV['SUB_ID']})
    elsif ENV['NQF_ID']
      measures = HealthDataStandards::CQM::Measure.any_in({nqf_id: ENV['NQF_ID'].split(",")}).sort(nqf_id: 1, sub_id: 1)
    elsif ENV['MEASURE_TYPE'] == "ep"
      measures = HealthDataStandards::CQM::Measure.all.where(type: "ep").sort(nqf_id: 1, sub_id: 1)
      filename.prepend "ep_"
    elsif ENV['MEASURE_TYPE'] == "eh"
      measures = HealthDataStandards::CQM::Measure.all.where(type: "eh").sort(nqf_id: 1, sub_id: 1)
      filename.prepend "eh_"
    else
      choose do |menu|
        menu.prompt = "Which measures? "
        HealthDataStandards::CQM::Measure.all.group_by(&:nqf_id).sort.each do |nqf_id, ms|
          menu.choice(nqf_id){ measures = ms }
        end
        menu.choice(:q, "quit") { say "quitter"; exit }
      end
    end
    effective_date = Time.gm(2014, 12, 31,23,59,00)
    measures.each do |measure|
      qr = QME::QualityReport.find_or_create(measure['id'], measure['sub_id'], {:effective_date=> effective_date.to_i, :enable_logging => false, :filters=> {} })
      qr.calculate({"oid_dictionary" =>OidHelper.generate_oid_dictionary(qr.measure)}, false) unless qr.calculated?
    end
    destination_dir = File.join(Rails.root, 'tmp', 'test_results')
    FileUtils.mkdir_p destination_dir
    puts "Measures: " + measures.map{|m| "#{m.nqf_id}#{m.sub_id}"}.join(",")
    puts "Rails env: #{Rails.env}"
    puts "Exporting #{destination_dir}/#{filename}..."
    output = File.open(File.join(destination_dir, filename), "w")
    output << exporter.export(measures, generate_header(Time.now), effective_date, Date.parse("2014-07-01"), Date.parse("2014-09-30"))
    output.close
  end

  def generate_header(time)
    Qrda::Header.new(YAML.load(File.read(File.join(Rails.root, 'config', 'qrda3_header.yml'))).deep_merge(legal_authenticator: {time: time}), authors: {time: time})
  end
end
