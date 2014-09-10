module Api

  class ReportsController < ApplicationController
    before_filter :authenticate_user!
skip_authorization_check
    def cat3
      measure_ids = params[:measure_ids] ||current_user.preferences["selected_measure_ids"]
      filter = measure_ids=="all" ? {}  : {:hqmf_id.in =>measure_ids}
      exporter =  HealthDataStandards::Export::Cat3.new
      effective_date = params["effective_date"] || current_user.effective_date
      end_date = Time.at(effective_date.to_i)
      render text: exporter.export(HealthDataStandards::CQM::Measure.top_level.where(filter),
                                   generate_header(Time.now),
                                   effective_date,
                                   end_date.years_ago(1),
                                   end_date)
    end

    private

    def generate_header(time)
      Qrda::Header.new(YAML.load(File.read(File.join(Rails.root, 'config', 'qrda3_header.yml'))).deep_merge(legal_authenticator: {time: time}), authors: {time: time})
    end
  end
end
