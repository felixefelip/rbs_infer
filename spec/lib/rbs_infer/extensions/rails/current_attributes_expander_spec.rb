# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/current_attributes_expander"

RSpec.describe RbsInfer::Extensions::Rails::CurrentAttributesExpander do
  def expand(source)
    described_class.expand(source)
  end

  it "returns nil for sources without CurrentAttributes" do
    expect(expand(<<~RUBY)).to be_nil
      class User < ApplicationRecord
        attribute :nickname, :string
      end
    RUBY
  end

  it "returns nil for a CurrentAttributes subclass without attribute calls" do
    expect(expand(<<~RUBY)).to be_nil
      class Current < ActiveSupport::CurrentAttributes
        def self.caderneta
          user.caderneta
        end
      end
    RUBY
  end

  it "expands attribute into the four accessors plus set/with" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user
      end
    RUBY

    expect(expanded).to eq(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        def user; @user; end
        def user=(value); @user = value; end
        def self.user; @user; end
        def self.user=(value); @user = value; end
        def self.set(user: nil, &block); @user = user; block.call; end
        def self.with(user: nil, &block); @user = user; block.call; end
      end
    RUBY
  end

  it "produces parseable Ruby" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user, :account, default: -> { Account.first }
      end
    RUBY

    expect(Prism.parse(expanded).success?).to be(true)
  end

  it "keeps real methods of the class untouched" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user

        def self.caderneta
          user.caderneta
        end
      end
    RUBY

    expect(expanded).to include("def self.caderneta\n    user.caderneta\n  end")
  end

  it "expands multiple names declared in one attribute call" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user, :account
      end
    RUBY

    expect(expanded).to include("def user; @user; end")
    expect(expanded).to include("def account; @account; end")
    expect(expanded).to include("def self.set(user: nil, account: nil, &block); @user = user; @account = account; block.call; end")
  end

  it "merges attributes from multiple attribute calls into set/with" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user
        attribute :account
      end
    RUBY

    # set/with são emitidos uma única vez, na última call, com TODOS os attrs
    expect(expanded.scan(/def self\.set\(/).length).to eq(1)
    expect(expanded).to include("def self.set(user: nil, account: nil, &block); @user = user; @account = account; block.call; end")
    expect(expanded.scan(/def self\.with\(/).length).to eq(1)
  end

  it "turns a lambda default into an initialize assignment with the lambda body" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :account, default: -> { Account.first }
      end
    RUBY

    expect(expanded).to include("def initialize\n    @account = Account.first\n  end")
  end

  it "uses literal defaults as-is" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :counter, default: 0
      end
    RUBY

    expect(expanded).to include("@counter = 0")
  end

  it "does not expand attribute calls on unrelated superclasses" do
    expect(expand(<<~RUBY)).to be_nil
      # menção a CurrentAttributes só no comentário
      class Form < ApplicationForm
        attribute :name
      end
    RUBY
  end

  it "does not expand attribute calls nested inside methods" do
    expect(expand(<<~RUBY)).to be_nil
      class Current < ActiveSupport::CurrentAttributes
        def self.configure
          attribute :late
        end
      end
    RUBY
  end
end
