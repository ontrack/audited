require "spec_helper"

SingleCov.covered! uncovered: 12 # not testing proxy_respond_to? hack / 2 methods / deprecation of `version`

describe Audited::Auditor do

  describe "configuration" do
    it "should include instance methods" do
      expect(Models::ActiveRecord::User.new).to be_a_kind_of( Audited::Auditor::AuditedInstanceMethods)
    end

    it "should include class methods" do
      expect(Models::ActiveRecord::User).to be_a_kind_of( Audited::Auditor::AuditedClassMethods )
    end

    ['created_at', 'updated_at', 'created_on', 'updated_on', 'lock_version', 'id', 'password'].each do |column|
      it "should not audit #{column}" do
        expect(Models::ActiveRecord::User.non_audited_columns).to include(column)
      end
    end

    context "should be configurable which conditions are audited" do
      subject { ConditionalCompany.new.send(:auditing_enabled) }

      context "when condition method is private" do
        subject { ConditionalPrivateCompany.new.send(:auditing_enabled) }

        before do
          class ConditionalPrivateCompany < ::ActiveRecord::Base
            self.table_name = 'companies'

            audited if: :foo?

            private def foo?
              true
            end
          end
        end

        it { is_expected.to be_truthy }
      end

      context "when passing a method name" do
        before do
          class ConditionalCompany < ::ActiveRecord::Base
            self.table_name = 'companies'

            audited if: :public?

            def public?; end
          end
        end

        context "when conditions are true" do
          before { allow_any_instance_of(ConditionalCompany).to receive(:public?).and_return(true) }
          it     { is_expected.to be_truthy }
        end

        context "when conditions are false" do
          before { allow_any_instance_of(ConditionalCompany).to receive(:public?).and_return(false) }
          it     { is_expected.to be_falsey }
        end
      end

      context "when passing a Proc" do
        context "when conditions are true" do
          before do
            class InclusiveCompany < ::ActiveRecord::Base
              self.table_name = 'companies'
              audited if: Proc.new { true }
            end
          end

          subject { InclusiveCompany.new.send(:auditing_enabled) }

          it { is_expected.to be_truthy }
        end

        context "when conditions are false" do
          before do
            class ExclusiveCompany < ::ActiveRecord::Base
              self.table_name = 'companies'
              audited if: Proc.new { false }
            end
          end
          subject { ExclusiveCompany.new.send(:auditing_enabled) }
          it { is_expected.to be_falsey }
        end
      end
    end

    context "should be configurable which conditions aren't audited" do
      context "when using a method name" do
        before do
          class ExclusionaryCompany < ::ActiveRecord::Base
            self.table_name = 'companies'

            audited unless: :non_profit?

            def non_profit?; end
          end
        end

        subject { ExclusionaryCompany.new.send(:auditing_enabled) }

        context "when conditions are true" do
          before { allow_any_instance_of(ExclusionaryCompany).to receive(:non_profit?).and_return(true) }
          it     { is_expected.to be_falsey }
        end

        context "when conditions are false" do
          before { allow_any_instance_of(ExclusionaryCompany).to receive(:non_profit?).and_return(false) }
          it     { is_expected.to be_truthy }
        end
      end

      context "when using a proc" do
        context "when conditions are true" do
          before do
            class ExclusionaryCompany < ::ActiveRecord::Base
              self.table_name = 'companies'
              audited unless: Proc.new { |c| c.exclusive? }

              def exclusive?
                true
              end
            end
          end

          subject { ExclusionaryCompany.new.send(:auditing_enabled) }
          it      { is_expected.to be_falsey }
        end

        context "when conditions are false" do
          before do
            class InclusiveCompany < ::ActiveRecord::Base
              self.table_name = 'companies'
              audited unless: Proc.new { false }
            end
          end

          subject { InclusiveCompany.new.send(:auditing_enabled) }
          it      { is_expected.to be_truthy }
        end
      end
    end

    it "should be configurable which attributes are not audited via ignored_attributes" do
      Audited.ignored_attributes = ['delta', 'top_secret', 'created_at']
      class Secret < ::ActiveRecord::Base
        audited
      end

      expect(Secret.non_audited_columns).to include('delta', 'top_secret', 'created_at')
    end

    it "should be configurable which attributes are not audited via non_audited_columns=" do
      class Secret2 < ::ActiveRecord::Base
        audited
        self.non_audited_columns = ['delta', 'top_secret', 'created_at']
      end

      expect(Secret2.non_audited_columns).to include('delta', 'top_secret', 'created_at')
    end

    it "should not save non-audited columns" do
      previous = Models::ActiveRecord::User.non_audited_columns
      begin
        Models::ActiveRecord::User.non_audited_columns += [:favourite_device]

        expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(
            audited_changes: hash_excluding('favourite_device', 'created_at', 'updated_at', 'password')
          )
        )

        create_user
      ensure
        Models::ActiveRecord::User.non_audited_columns = previous
      end
    end

    it "should not save other columns than specified in 'only' option" do
      user = Models::ActiveRecord::UserOnlyPassword.create
      user.instance_eval do
        def non_column_attr
          @non_column_attr
        end

        def non_column_attr=(val)
          attribute_will_change!("non_column_attr")
          @non_column_attr = val
        end
      end

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: { "password" => [nil, "password"] }
        )
      )

      user.password = "password"
      user.non_column_attr = "some value"
      user.save!
    end

    it "should save attributes not specified in 'except' option" do
      user = Models::ActiveRecord::User.create
      user.instance_eval do
        def non_column_attr
          @non_column_attr
        end

        def non_column_attr=(val)
          attribute_will_change!("non_column_attr")
          self[:non_column_attr] = val
        end
      end

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: { "non_column_attr" => [nil, "some value"] }
        )
      )

      user.password = "password"
      user.non_column_attr = "some value"
      user.save!
    end

    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      describe "'json' and 'jsonb' audited_changes column type" do
        let(:migrations_path) { SPEC_ROOT.join("support/active_record/postgres") }

        after do
          run_migrations(:down, migrations_path)
        end

        it "should work if column type is 'json'" do
          run_migrations(:up, migrations_path, 1)
          Audited::Audit.reset_column_information
          expect(Audited::Audit.columns_hash["audited_changes"].sql_type).to eq("json")

          expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
            hash_including(
              audited_changes: {"name" => [nil, "new name"]}
            )
          )

          user = Models::ActiveRecord::User.create
          user.name = "new name"
          user.save!
        end

        it "should work if column type is 'jsonb'" do
          run_migrations(:up, migrations_path, 2)
          Audited::Audit.reset_column_information
          expect(Audited::Audit.columns_hash["audited_changes"].sql_type).to eq("jsonb")

          expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
            hash_including(
              audited_changes: {"name" => [nil, "new name"]}
            )
          )

          user = Models::ActiveRecord::User.create
          user.name = "new name"
          user.save!
        end
      end
    end
  end

  describe :new do
    it "should allow mass assignment of all unprotected attributes" do
      yesterday = 1.day.ago

      u = Models::ActiveRecord::NoAttributeProtectionUser.new(name: 'name',
                                        username: 'username',
                                        password: 'password',
                                        activated: true,
                                        suspended_at: yesterday,
                                        logins: 2)

      expect(u.name).to eq('name')
      expect(u.username).to eq('username')
      expect(u.password).to eq('password')
      expect(u.activated).to eq(true)
      expect(u.suspended_at.to_i).to eq(yesterday.to_i)
      expect(u.logins).to eq(2)
    end
  end

  describe "on create" do
    let( :user ) { create_user status: :reliable, audit_comment: "Create" }

    it "should create associated audit" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call)
      user
    end

    it "should set the action to create" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          action: "create",
        )
      )

      user
    end

    it "should store all of the audited attributes" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: user.audited_attributes
        )
      )
      create_user status: :reliable, audit_comment: "Create"
    end

    it "should store enum value" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: hash_including("status" => 1)
        )
      )
      user
    end

    it "should store comment" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          comment: "Create"
        )
      )
      user
    end

    it "should not audit an attribute which is excepted if specified on create or destroy" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: hash_excluding("name")
        )
      )
      Models::ActiveRecord::OnCreateDestroyExceptName.create(name: 'Bart')
    end

    it "should not save an audit if only specified on update/destroy" do
      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)
      Models::ActiveRecord::OnUpdateDestroy.create!( name: 'Bart' )
    end
  end

  describe "on update" do
    before do
      @user = create_user( name: 'Brandon', status: :active, audit_comment: 'Update' )
    end

    it "should save an audit" do
      call_count = 0
      allow_any_instance_of(Audited::Audit).to receive(:audit_job_call) { |args| call_count += 1 }

      @user.update_attribute(:name, "Someone")
      @user.update_attribute(:name, "Someone else")

      expect(call_count).to eq 2
    end

    it "should set the action to 'update'" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          action: "update"
        )
      )
      @user.update_attributes name: 'Changed'
    end

    it "should store the changed attributes" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: { 'name' => ['Brandon', 'Changed'] }
        )
      )
      @user.update_attributes name: 'Changed'
    end

    it "should store changed enum values" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: hash_including("status" => [0, 1])
        )
      )
      @user.update_attributes status: 1
    end

    it "should store audit comment" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          comment: "Update"
        )
      )
      create_user( name: 'Brandon', status: :active, audit_comment: 'Update' )
    end

    it "should not save an audit if only specified on create/destroy" do
      on_create_destroy = Models::ActiveRecord::OnCreateDestroy.create( name: 'Bart' )

      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)

      on_create_destroy.update_attributes name: 'Changed'
    end

    it "should not save an audit if the value doesn't change after type casting" do
      @user.update_attributes! logins: 0, activated: true

      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)

      @user.update_attribute :logins, '0'
      @user.update_attribute :activated, 1
      @user.update_attribute :activated, '1'
    end

    it "should not save if the changed value is blank" do
      @user.update_attribute :username, nil
      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)
      @user.update_attribute :username, ''
    end

    it "should save if the changed value is blank" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: { 'name' => ['Brandon', ''] }
        )
      )
      @user.update_attributes name: ''
    end

    describe "with no dirty changes" do
      it "does not create an audit if the record is not changed" do
        expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)
        @user.save!
      end

      it "creates an audit when an audit comment is present" do
        expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(
            comment: "Comment"
          )
        )
        @user.audit_comment = "Comment"
        @user.save!
      end
    end
  end

  describe "on destroy" do
    before do
      @user = create_user(status: :active)
    end

    it "should save an audit" do
      call_count = 0
      allow_any_instance_of(Audited::Audit).to receive(:audit_job_call) { |args| call_count += 1 }

      user = create_user(status: :active)
      user.destroy

      expect(call_count).to eq 2
    end

    it "should set the action to 'destroy'" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          action: "destroy"
        )
      )
      @user.destroy
    end

    it "should store all of the audited attributes" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: @user.audited_attributes
        )
      )
      @user.destroy
    end

    it "should store enum value" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          audited_changes: hash_including("status" => 0)
        )
      )
      @user.destroy
    end

    it "should not save an audit if only specified on create/update" do
      on_create_update = Models::ActiveRecord::OnCreateUpdate.create!( name: 'Bart' )

      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)

      on_create_update.destroy
    end

    it "should audit dependent destructions" do
      owner = Models::ActiveRecord::Owner.create!

      call_count = 0
      allow_any_instance_of(Audited::Audit).to receive(:audit_job_call) { |args| call_count += 1 }

      company = owner.companies.create!
      owner.destroy

      expect(call_count).to eq(3)
    end
  end

  describe "on destroy with unsaved object" do
    let(:user) { Models::ActiveRecord::User.new }

    it "should not audit on 'destroy'" do
      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)
      user.destroy
    end
  end

  describe "on destroy in transaction" do
    let(:user) { create_user }

    it "should save an audit" do
      call_count = 0
      allow_any_instance_of(Audited::Audit).to receive(:audit_job_call) { call_count += 1 }

      user.transaction { user.destroy }

      expect(call_count).to eq(2)
    end
  end

  describe "associated with" do
    let(:owner) { Models::ActiveRecord::Owner.create(name: 'Models::ActiveRecord::Owner') }
    let(:owned_company) { Models::ActiveRecord::OwnedCompany.create!(name: 'The auditors', owner: owner) }

    it "should record the associated object on create" do
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          associated_id: owner.id,
          associated_type: owner.class.name,
        )
      )
      owned_company
    end

    it "should store the associated object on update" do
      owned_company
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          associated_id: owner.id,
          associated_type: owner.class.name,
        )
      )
      owned_company.update_attribute(:name, 'The Auditors')
    end

    it "should store the associated object on destroy" do
      owned_company
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(
          associated_id: owner.id,
          associated_type: owner.class.name,
        )
      )
      owned_company.destroy
    end
  end

  describe "without auditing" do
    it "should not save an audit when calling #save_without_auditing" do
      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)
      u = Models::ActiveRecord::User.new(name: 'Brandon')
      expect(u.save_without_auditing).to eq(true)
    end

    it "should not save an audit inside of the #without_auditing block" do
      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)
      Models::ActiveRecord::User.without_auditing { Models::ActiveRecord::User.create!( name: 'Brandon' ) }
    end

    context "auditing is globally disabled" do
      it "should not leave model with forever disabled auditing after #without_auditing block" do
        expect(Audited.auditing_enabled).to eq(true)
        Audited.auditing_enabled = false

        expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call).with(
          hash_including(action: "create")
        )
        user = Models::ActiveRecord::User.without_auditing do
          expect(Models::ActiveRecord::User.auditing_enabled).to eq(false)
          create_user
        end

        Audited.auditing_enabled = true
        expect(Models::ActiveRecord::User.auditing_enabled).to eq(true)

        expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(action: "update")
        )
        user.update_attributes(name: 'Test')
      end
    end

    it "should reset auditing status even it raises an exception" do
      Models::ActiveRecord::User.without_auditing { raise } rescue nil
      expect(Models::ActiveRecord::User.auditing_enabled).to eq(true)
    end

    it "should be thread safe using a #without_auditing block" do
      skip if Models::ActiveRecord::User.connection.class.name.include?("SQLite")

      t1 = Thread.new do
        expect(Models::ActiveRecord::User.auditing_enabled).to eq(true)
        Models::ActiveRecord::User.without_auditing do
          expect(Models::ActiveRecord::User.auditing_enabled).to eq(false)
          Models::ActiveRecord::User.create!( name: 'Bart' )
          sleep 1
          expect(Models::ActiveRecord::User.auditing_enabled).to eq(false)
        end
        expect(Models::ActiveRecord::User.auditing_enabled).to eq(true)
      end

      t2 = Thread.new do
        sleep 0.5
        expect(Models::ActiveRecord::User.auditing_enabled).to eq(true)
        Models::ActiveRecord::User.create!( name: 'Lisa' )
      end

      call_count = 0
      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call) { call_count += 1 }

      t1.join
      t2.join

      expect(call_count).to eq(1)
    end

    it "should not save an audit when auditing is globally disabled" do
      expect(Audited.auditing_enabled).to eq(true)
      Audited.auditing_enabled = false
      expect(Models::ActiveRecord::User.auditing_enabled).to eq(false)

      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call).with(
        hash_including(action: "create")
      )
      user = create_user

      Audited.auditing_enabled = true
      expect(Models::ActiveRecord::User.auditing_enabled).to eq(true)

      expect_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
        hash_including(action: "update")
      )
      user.update_attributes(name: 'Test')
    end
  end

  describe "comment required" do

    describe "on create" do
      it "should not validate when audit_comment is not supplied when initialized" do
        expect(Models::ActiveRecord::CommentRequiredUser.new(name: 'Foo')).not_to be_valid
      end

      it "should not validate when audit_comment is not supplied trying to create" do
        expect(Models::ActiveRecord::CommentRequiredUser.create(name: 'Foo')).not_to be_valid
      end

      it "should validate when audit_comment is supplied" do
        expect(Models::ActiveRecord::CommentRequiredUser.create(name: 'Foo', audit_comment: 'Create')).to be_valid
      end

      it "should validate when audit_comment is not supplied, and creating is not being audited" do
        expect(Models::ActiveRecord::OnUpdateCommentRequiredUser.create(name: 'Foo')).to be_valid
        expect(Models::ActiveRecord::OnDestroyCommentRequiredUser.create(name: 'Foo')).to be_valid
      end

      it "should validate when audit_comment is not supplied, and auditing is disabled" do
        Models::ActiveRecord::CommentRequiredUser.disable_auditing
        expect(Models::ActiveRecord::CommentRequiredUser.create(name: 'Foo')).to be_valid
        Models::ActiveRecord::CommentRequiredUser.enable_auditing
      end
    end

    describe "on update" do
      let( :user ) { Models::ActiveRecord::CommentRequiredUser.create!( audit_comment: 'Create' ) }
      let( :on_create_user ) { Models::ActiveRecord::OnDestroyCommentRequiredUser.create }
      let( :on_destroy_user ) { Models::ActiveRecord::OnDestroyCommentRequiredUser.create }

      it "should not validate when audit_comment is not supplied" do
        expect(user.update_attributes(name: 'Test')).to eq(false)
      end

      it "should validate when audit_comment is not supplied, and updating is not being audited" do
        expect(on_create_user.update_attributes(name: 'Test')).to eq(true)
        expect(on_destroy_user.update_attributes(name: 'Test')).to eq(true)
      end

      it "should validate when audit_comment is supplied" do
        expect(user.update_attributes(name: 'Test', audit_comment: 'Update')).to eq(true)
      end

      it "should validate when audit_comment is not supplied, and auditing is disabled" do
        Models::ActiveRecord::CommentRequiredUser.disable_auditing
        expect(user.update_attributes(name: 'Test')).to eq(true)
        Models::ActiveRecord::CommentRequiredUser.enable_auditing
      end
    end

    describe "on destroy" do
      let( :user ) { Models::ActiveRecord::CommentRequiredUser.create!( audit_comment: 'Create' )}
      let( :on_create_user ) { Models::ActiveRecord::OnCreateCommentRequiredUser.create!( audit_comment: 'Create' ) }
      let( :on_update_user ) { Models::ActiveRecord::OnUpdateCommentRequiredUser.create }

      it "should not validate when audit_comment is not supplied" do
        expect(user.destroy).to eq(false)
      end

      it "should validate when audit_comment is supplied" do
        user.audit_comment = "Destroy"
        expect(user.destroy).to eq(user)
      end

      it "should validate when audit_comment is not supplied, and destroying is not being audited" do
        expect(on_create_user.destroy).to eq(on_create_user)
        expect(on_update_user.destroy).to eq(on_update_user)
      end

      it "should validate when audit_comment is not supplied, and auditing is disabled" do
        Models::ActiveRecord::CommentRequiredUser.disable_auditing
        expect(user.destroy).to eq(user)
        Models::ActiveRecord::CommentRequiredUser.enable_auditing
      end
    end

  end

  describe "attr_protected and attr_accessible" do

    it "should not raise error when attr_accessible is set and protected is false" do
      expect {
        Models::ActiveRecord::AccessibleAfterDeclarationUser.new(name: 'No fail!')
      }.to_not raise_error
    end

    it "should not rause an error when attr_accessible is declared before audited" do
      expect {
        Models::ActiveRecord::AccessibleAfterDeclarationUser.new(name: 'No fail!')
      }.to_not raise_error
    end
  end

  describe "audit_as" do
    let( :user ) { Models::ActiveRecord::User.create name: 'Testing' }

    it "should record user objects" do
      Models::ActiveRecord::Company.audit_as( user ) do
        call_count = 0
        allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(user_id: user.id)
        ) { call_count += 1 }

        company = Models::ActiveRecord::Company.create name: "The auditors"
        company.update_attributes name: "The Auditors"

        expect(call_count).to eq(2)
      end
    end

    it "should record usernames" do
      Models::ActiveRecord::Company.audit_as( user.name ) do
        call_count = 0
        allow_any_instance_of(Audited::Audit).to receive(:audit_job_call).with(
          hash_including(username: user.name)
        ) { call_count += 1 }

        company = Models::ActiveRecord::Company.create name: "The auditors"
        company.update_attributes name: "The Auditors"

        expect(call_count).to eq(2)
      end
    end
  end

  describe "after_audit" do
    let( :user ) { Models::ActiveRecord::UserWithAfterAudit.new }

    it "should invoke after_audit callback on create" do
      expect(user.bogus_attr).to be_nil
      expect(user.save).to eq(true)
      expect(user.bogus_attr).to eq("do something")
    end
  end

  describe "STI auditing" do
    it "should correctly disable auditing when using STI" do
      company = Models::ActiveRecord::Company::STICompany.create name: 'The auditors'
      expect(company.type).to eq("Models::ActiveRecord::Company::STICompany")

      Models::ActiveRecord::Company.auditing_enabled = false
      expect_any_instance_of(Audited::Audit).to_not receive(:audit_job_call)
      company.update_attributes name: 'STI auditors'
      Models::ActiveRecord::Company.auditing_enabled = true
    end
  end
end
