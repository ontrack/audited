require "spec_helper"

SingleCov.covered! uncovered: 2 # 2 conditional on_load conditions

class AuditsController < ActionController::Base
  before_action :populate_user

  attr_reader :company

  def create
    @company = Models::ActiveRecord::Company.create
    head :ok
  end

  def update
    current_user.update_attributes(password: 'foo')
    head :ok
  end

  private

  attr_accessor :current_user
  attr_accessor :custom_user

  def populate_user; end
end

describe AuditsController do
  include RSpec::Rails::ControllerExampleGroup
  render_views

  before do
    Audited.current_user_method = :current_user
  end

  let(:user) { create_user }

  describe "POST audit" do
    it "should audit user" do
      controller.send(:current_user=, user)

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(user_id: user.id)
      )

      post :create
    end

    it "does not audit when method is not found" do
      controller.send(:current_user=, user)
      Audited.current_user_method = :nope

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(user_id: nil)
      )

      post :create
    end

    it "should support custom users for sweepers" do
      controller.send(:custom_user=, user)
      Audited.current_user_method = :custom_user

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call)

      post :create
    end

    it "should record the remote address responsible for the change" do
      request.env['REMOTE_ADDR'] = "1.2.3.4"
      controller.send(:current_user=, user)

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(remote_address: "1.2.3.4")
      )

      post :create
    end

    it "should record a UUID for the web request responsible for the change" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:uuid).and_return("abc123")
      controller.send(:current_user=, user)

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(request_uuid: "abc123")
      )

      post :create
    end

    it "should call current_user after controller callbacks" do
      expect(controller).to receive(:populate_user) do
        controller.send(:current_user=, user)
      end

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(user_id: user.id)
      )

      post :create
    end
  end

  describe "PUT update" do
    it "should not save blank audits" do
      controller.send(:current_user=, user)

      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)

      put :update, Rails::VERSION::MAJOR == 4 ? {id: 123} : {params: {id: 123}}
    end
  end
end

describe Audited::Sweeper do

  it "should be thread-safe" do
    instance = Audited::Sweeper.new

    t1 = Thread.new do
      sleep 0.5
      instance.controller = 'thread1 controller instance'
      expect(instance.controller).to eq('thread1 controller instance')
    end

    t2 = Thread.new do
      instance.controller = 'thread2 controller instance'
      sleep 1
      expect(instance.controller).to eq('thread2 controller instance')
    end

    t1.join; t2.join

    expect(instance.controller).to be_nil
  end

end
