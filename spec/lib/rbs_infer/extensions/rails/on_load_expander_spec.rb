# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/on_load_expander"

RSpec.describe RbsInfer::Extensions::Rails::OnLoadExpander do
  def expand(source)
    described_class.expand(source)
  end

  it "returns nil for sources without on_load" do
    expect(expand(<<~RUBY)).to be_nil
      class User < ApplicationRecord
      end
    RUBY
  end

  it "returns nil for an unrecognized load hook" do
    expect(expand(<<~RUBY)).to be_nil
      ActiveSupport.on_load :some_custom_hook do
        def foo; end
      end
    RUBY
  end

  it "returns nil when on_load is not called on ActiveSupport" do
    expect(expand(<<~RUBY)).to be_nil
      Other.on_load :active_storage_blob do
        def foo; end
      end
    RUBY
  end

  it "rewrites a known hook block into a class reopening" do
    expanded = expand(<<~RUBY)
      ActiveSupport.on_load :active_storage_blob do
        def accessible_to?(user)
          true
        end
      end
    RUBY

    expect(expanded).to eq(<<~RUBY.chomp + "\n")
      class ActiveStorage::Blob
      def accessible_to?(user)
          true
        end
      end
    RUBY
    expect(Prism.parse(expanded).success?).to be(true)
  end

  it "rewrites multiple on_load blocks in one file" do
    expanded = expand(<<~RUBY)
      ActiveSupport.on_load :active_storage_blob do
        def a; end
      end

      ActiveSupport.on_load :active_storage_attachment do
        def b; end
      end
    RUBY

    expect(expanded).to include("class ActiveStorage::Blob")
    expect(expanded).to include("class ActiveStorage::Attachment")
    expect(Prism.parse(expanded).success?).to be(true)
  end

  it "maps the common Rails framework hooks" do
    {
      "active_record" => "ActiveRecord::Base",
      "action_controller" => "ActionController::Base",
      "action_mailer" => "ActionMailer::Base",
      "active_job" => "ActiveJob::Base",
    }.each do |hook, klass|
      expanded = expand("ActiveSupport.on_load :#{hook} do\n  def x; end\nend\n")
      expect(expanded).to include("class #{klass}"), "expected :#{hook} → #{klass}"
    end
  end
end
