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
        def user
          @user
        end

        def user=(value)
          @user = value
        end

        def self.user
          @user
        end

        def self.user=(value)
          @user = value
        end

        def self.set(user: nil, &block)
          @user = user
          block.call
        end

        def self.with(user: nil, &block)
          @user = user
          block.call
        end
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

    expect(expanded).to include("def user\n    @user\n  end")
    expect(expanded).to include("def account\n    @account\n  end")
    expect(expanded).to include("def self.set(user: nil, account: nil, &block)\n    @user = user\n    @account = account\n    block.call\n  end")
  end

  it "merges attributes from multiple attribute calls into set/with" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user
        attribute :account
      end
    RUBY

    # set/with are emitted once, at the last call, with ALL the attrs
    expect(expanded.scan(/def self\.set\(/).length).to eq(1)
    expect(expanded).to include("def self.set(user: nil, account: nil, &block)")
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

  it "skips accessors the class body overrides and desugars their super" do
    # Padrão dos Rails guides: override do setter chamando super.
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user, :caderneta

        def user=(value)
          super(value)

          if value.present?
            self.caderneta = value.caderneta
          end
        end
      end
    RUBY

    # O setter de instância NÃO é gerado (a classe define o seu)...
    expect(expanded.scan(/def user=/).length).to eq(1)
    # ...e o super vira o write de ivar (o accessor gerado É o ivar write)
    expect(expanded).to include("def user=(value)\n    @user = value\n")
    expect(expanded).not_to include("super")
    # Os demais accessors continuam gerados
    expect(expanded).to include("def user\n    @user\n  end")
    expect(expanded).to include("def self.user=(value)")
    expect(expanded).to include("def caderneta=(value)")
    expect(Prism.parse(expanded).success?).to be(true)
  end

  it "desugars bare super forwarding the override's param" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user

        def user=(novo_user)
          super
        end
      end
    RUBY

    expect(expanded).to include("def user=(novo_user)\n    @user = novo_user\n  end")
  end

  it "desugars super in a getter override to the ivar read" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user

        def user
          super || User.new
        end
      end
    RUBY

    expect(expanded).to include("def user\n    @user || User.new\n  end")
  end

  it "leaves super in non-accessor methods untouched" do
    expanded = expand(<<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user

        def self.reset
          super
        end
      end
    RUBY

    expect(expanded).to include("def self.reset\n    super\n  end")
  end

  describe ".overridden_accessors" do
    it "lists attribute accessors the class body overrides" do
      overrides = described_class.overridden_accessors(<<~RUBY)
        class Current < ActiveSupport::CurrentAttributes
          attribute :user, :account

          def user=(value)
            super
          end

          def self.account
            super
          end

          def unrelated_method; end
        end
      RUBY

      expect(overrides).to contain_exactly(
        { method: "user=", attr: "user", singleton: false },
        { method: "account", attr: "account", singleton: true }
      )
    end

    it "returns [] for non-CurrentAttributes sources" do
      expect(described_class.overridden_accessors("class Foo; end")).to eq([])
    end
  end

  describe ".attribute_names" do
    it "lists attribute names across declarations" do
      names = described_class.attribute_names(<<~RUBY)
        class Current < ActiveSupport::CurrentAttributes
          attribute :user, :account
          attribute :request_id
        end
      RUBY

      expect(names).to eq(%w[user account request_id])
    end

    it "returns [] for non-CurrentAttributes sources" do
      expect(described_class.attribute_names("class Foo < ApplicationRecord; end")).to eq([])
    end
  end

  it "does not expand attribute calls on unrelated superclasses" do
    expect(expand(<<~RUBY)).to be_nil
      # CurrentAttributes mentioned only in this comment
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
