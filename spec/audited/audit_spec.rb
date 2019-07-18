require "spec_helper"

SingleCov.covered!

describe Audited::Audit do
  let(:user) { Models::ActiveRecord::User.new name: "Testing" }

  describe "audit class" do
    around(:example) do |example|
      original_audit_class = Audited.audit_class

      class CustomAudit < Audited::Audit
        def custom_method
          "I'm custom!"
        end
      end

      class TempModel < ::ActiveRecord::Base
        self.table_name = :companies
      end

      example.run

      Audited.config { |config| config.audit_class = original_audit_class }
      Object.send(:remove_const, :TempModel)
      Object.send(:remove_const, :CustomAudit)
    end

    context "when a custom audit class is configured" do
      it "should be used in place of #{described_class}" do
        Audited.config { |config| config.audit_class = CustomAudit }
        TempModel.audited

        expect(CustomAudit).to receive(:new).and_call_original
        expect(Audited::Audit).to_not receive(:new)

        TempModel.create
      end
    end

    context "when a custom audit class is not configured" do
      it "should default to #{described_class}" do
        TempModel.audited

        expect(Audited::Audit).to receive(:new).and_call_original
        expect(CustomAudit).to_not receive(:new)

        TempModel.create
      end
    end
  end

  describe "#audited_changes" do
    let(:audit) { Audited.audit_class.new }

    it "can unserialize yaml from hash" do
      audit.audited_changes = { foo: "bar" }
      expect(audit.audited_changes).to eq foo: "bar"
    end

    it "can unserialize yaml from text columns" do
      audit.audited_changes = "---\nfoo: bar"
      expect(audit.audited_changes).to eq "foo" => "bar"
      audit.audited_changes = ""
      expect(audit.audited_changes).to eq({})
    end
  end

  it "should set the version number on create" do
    expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
      hash_including(version: a_kind_of(Integer))
    )
    Models::ActiveRecord::User.create! name: "Set Version Number"
  end

  it "should set the request uuid on create" do
    expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
      hash_including(request_uuid: a_kind_of(String))
    )
    Models::ActiveRecord::User.create! name: "Set Request UUID"
  end

  describe "as_user" do
    it "should record user objects" do
      Audited::Audit.as_user(user) do
        call_count = 0
        allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(user_id: user.id)
        ) { call_count += 1 }

        company = Models::ActiveRecord::Company.create name: "The auditors"
        company.update_attributes name: "The Auditors"

        expect(call_count).to eq(2)
      end
    end

    it "should support nested as_user" do
      user2_count = 0
      allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(user_id: user.id)
      ) { user2_count += 1 }

      user1_count = 0
      allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(username: "sidekiq")
      ) { user1_count += 1 }

      Audited::Audit.as_user("sidekiq") do
        company = Models::ActiveRecord::Company.create name: "The auditors"
        company.name = "The Auditors, Inc"
        company.save

        Audited::Audit.as_user(user) do
          company.name = "NEW Auditors, Inc"
          company.save
        end

        company.name = "LAST Auditors, Inc"
        company.save
      end

      expect(user1_count).to eq(3)
      expect(user2_count).to eq(1)
    end

    it "should record usernames" do
      Audited::Audit.as_user(user.name) do
        call_count = 0
        allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(username: user.name)
        ) { call_count += 1 }

        company = Models::ActiveRecord::Company.create name: "The auditors"
        company.name = "The Auditors, Inc"
        company.save

        expect(call_count).to eq(2)
      end
    end

    it "should be thread safe" do
      skip if ActiveRecord::Base.connection.adapter_name == 'SQLite'

      begin
        expect(user.save).to eq(true)

        user2_count = 0
        allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(user_id: user.id)
        ) { user2_count += 1 }

        user1_count = 0
        allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(username: user.name)
        ) { user1_count += 1 }

        t1 = Thread.new do
          Audited::Audit.as_user(user) do
            sleep 1
            Models::ActiveRecord::Company.create(name: "The Auditors, Inc")
          end
        end

        t2 = Thread.new do
          Audited::Audit.as_user(user.name) do
            Models::ActiveRecord::Company.create(name: "The Competing Auditors, LLC")
            sleep 0.5
          end
        end

        t1.join
        t2.join

        expect(user1_count).to eq(1)
        expect(user2_count).to eq(1)
      end
    end

    it "should return the value from the yield block" do
      result = Audited::Audit.as_user('foo') do
        42
      end
      expect(result).to eq(42)
    end

    it "should reset audited_user when the yield block raises an exception" do
      expect {
        Audited::Audit.as_user('foo') do
          raise StandardError.new('expected')
        end
      }.to raise_exception('expected')
      expect(Audited.store[:audited_user]).to be_nil
    end
  end
end
