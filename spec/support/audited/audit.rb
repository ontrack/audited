module Audited
  class Audit
    include Virtus.model
    include ActiveRecord::DefineCallbacks

    class Yaml < Virtus::Attribute
      def coerce(value)
        return value if value.is_a?(Hash)
        return {} if value.to_s.blank?
        ActiveRecord::Coders::YAMLColumn.new(Object).load(value)
      end
    end

    class DateTimeWithZone < Virtus::Attribute
      primitive DateTime

      def coerce(value)
        return if value.blank?
        date = Time.zone.parse(value.to_s)
        return if date.blank?
        date
      end
    end

    attribute :action, String
    attribute :admin_user_id, Integer
    attribute :associated_id, Integer
    attribute :associated_name, String
    attribute :associated_type, String
    attribute :auditable_id, Integer
    attribute :auditable_type, String
    attribute :audited_changes, Yaml
    attribute :city, String
    attribute :client_hashed_id, String
    attribute :client_name, String
    attribute :comment, String
    attribute :country, String
    attribute :created_at, DateTimeWithZone
    attribute :id, Integer, default: 0
    attribute :info, Yaml
    attribute :latitude, Float
    attribute :longitude, Float
    attribute :practice_id, Integer
    attribute :remote_address, String
    attribute :request_uuid, String
    attribute :sub_type, String
    attribute :user_id, Integer
    attribute :user_type, String
    attribute :username, String
    attribute :version, Integer

    before_create :set_version_number, :set_audit_user, :set_request_uuid, :set_remote_address

    # All audits made during the block called will be recorded as made
    # by +user+. This method is hopefully threadsafe, making it ideal
    # for background operations that require audit information.
    def self.as_user(user)
      last_audited_user = ::Audited.store[:audited_user]
      ::Audited.store[:audited_user] = user
      yield
    ensure
      ::Audited.store[:audited_user] = last_audited_user
    end

    def save
      run_callbacks :create
      audit_job_call(attributes)
      true
    end

    def audit_job_call(attrs)
      # no-op
    end

    def auditable
      return unless auditable_type
      @auditable ||= auditable_type.constantize.find_by(id: auditable_id)
    end

    def auditable=(model)
      @auditable_id = model.id
      @auditable_type = model.class.base_class.name
    end

    def associated
      return unless associated_type
      @associated ||= associated_type.constantize.find_by(id: associated_id)
    end

    def associated=(model)
      @associated_id = model.try(:id)
      @associated_type = model.class.try(:base_class).try(:name)
    end

    def user
      return unless user_type
      @user ||= user_type.constantize.find(user_id)
    end

    def user=(model)
      @user_id = model.try(:id)
      @user_type = model.class.try(:base_class).try(:name)
    end

    private

    def set_version_number
      @version = created_at.to_i
    end

    def set_audit_user
      if ::Audited.store[:audited_user].is_a?(::ActiveRecord::Base)
        self.user = ::Audited.store[:audited_user]
      else
        self.username = ::Audited.store[:audited_user]
      end

      self.user ||= ::Audited.store[:current_user].try!(:call)
    end

    def set_request_uuid
      @request_uuid ||= ::Audited.store[:current_request_uuid]
      @request_uuid ||= SecureRandom.uuid
    end

    def set_remote_address
      @remote_address ||= ::Audited.store[:current_remote_address]
    end
  end
end
