require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::SteepBridge, :dummy_app do
  subject(:bridge) { described_class.new }

  describe "#local_var_types_per_method" do
    it "resolves constant receiver method calls" do
      code = <<~RUBY
        class Foo
          def bar
            comment = Comment.find(1)
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["comment"]).to eq("(Comment & Comment::Validated)")
    end

    it "resolves chained method calls" do
      code = <<~RUBY
        class Foo
          def bar
            user = User.where(active: true).first
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["user"]).to eq("(User & User::Validated)?")
    end

    it "resolves comparison operators to bool" do
      code = <<~RUBY
        class Foo
          def bar
            result = 42 > 10
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["result"]).to eq("bool")
    end

    it "separates variables by method" do
      code = <<~RUBY
        class Foo
          def bar
            x = Comment.find(1)
          end

          def baz
            y = 42
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["x"]).to eq("(Comment & Comment::Validated)")
      expect(result["baz"]["y"]).to eq("Integer")
      expect(result["bar"]).not_to have_key("y")
    end

    it "skips untyped and nil assignments" do
      code = <<~RUBY
        class Foo
          def bar
            x = nil
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]).not_to have_key("x")
    end

    it "returns empty hash for unparseable code" do
      result = bridge.local_var_types_per_method("!!!invalid ruby")
      expect(result).to eq({})
    end

    it "captures single block parameter (procarg0)" do
      code = <<~RUBY
        class Foo
          def bar
            [1, 2, 3].map do |num|
              num
            end
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["num"]).to eq("Integer")
    end

    it "captures multiple block parameters (arg)" do
      code = <<~RUBY
        class Foo
          def bar
            [1, 2, 3].each_with_index do |num, idx|
              num + idx
            end
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["num"]).to eq("Integer")
      expect(result["bar"]["idx"]).to eq("Integer")
    end

    it "captures hash each block parameters" do
      code = <<~RUBY
        class Foo
          def bar
            { a: 1, b: 2 }.each do |key, val|
              puts key
            end
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["key"]).to eq("Symbol")
      expect(result["bar"]["val"]).to eq("Integer")
    end

    it "does not capture def params as typed (they are untyped without RBS)" do
      code = <<~RUBY
        class Foo
          def bar(x, y)
            z = 42
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]).not_to have_key("x")
      expect(result["bar"]).not_to have_key("y")
      expect(result["bar"]["z"]).to eq("Integer")
    end

    it "captures block params alongside local var assignments" do
      code = <<~RUBY
        class Foo
          def bar
            total = 0
            [1, 2, 3].each do |num|
              total += num
            end
            total
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["num"]).to eq("Integer")
      expect(result["bar"]["total"]).to eq("Integer")
    end
  end

  describe "#method_return_types" do
    it "resolves method return types from body expressions" do
      code = <<~RUBY
        class Foo
          def bar
            42 > 10
          end
        end
      RUBY

      result = bridge.method_return_types(code)
      expect(result["bar"]).to eq("bool")
    end

    it "collapses Steep Logic types to bool (regression for Logic::Not leaking into RBS)" do
      # `!@x.nil?` and similar predicate bodies type as
      # `Steep::AST::Types::Logic::*` internally — unprintable types
      # Steep uses for predicate flow narrowing. Without explicit
      # handling, `to_s` emits `<% Steep::AST::Types::Logic::Not %>`
      # which leaks into the generated RBS as a literal `Logic::Not`
      # string. Verify the helper collapses each Logic type to `bool`.
      expect(bridge.send(:format_type, Steep::AST::Types::Logic::Not.instance)).to eq("bool")
      expect(bridge.send(:format_type, Steep::AST::Types::Logic::ReceiverIsNil.instance)).to eq("bool")
      expect(bridge.send(:format_type, Steep::AST::Types::Logic::ReceiverIsArg.instance)).to eq("bool")
      expect(bridge.send(:format_type, Steep::AST::Types::Logic::ArgIsReceiver.instance)).to eq("bool")
    end

    it "resolves chained method return types" do
      code = <<~RUBY
        class Foo
          def bar
            User.where(active: true).first
          end
        end
      RUBY

      result = bridge.method_return_types(code)
      expect(result["bar"]).to eq("(User & User::Validated)?")
    end

    it "excludes empty methods" do
      code = <<~RUBY
        class Foo
          def bar
          end
        end
      RUBY

      result = bridge.method_return_types(code)
      expect(result).not_to have_key("bar")
    end

    it "normalizes void in union types to nilable" do
      code = <<~RUBY
        class TagDestroy
          def verify_multiples_returns_with_void_and_rescue
            User.find(1).save!
          rescue StandardError => e
            "error"
          end
        end
      RUBY

      result = bridge.method_return_types(code)
      ret = result["verify_multiples_returns_with_void_and_rescue"]
      expect(ret).to match(/String\??/)
      expect(ret).not_to include("void")
    end

    it "returns empty hash for unparseable code" do
      result = bridge.method_return_types("!!!invalid ruby")
      expect(result).to eq({})
    end
  end

  describe "#method_return_types block generic resolution" do
    it "resolves .map block body type when Steep returns Array[untyped]" do
      code = File.read(File.join(__dir__, "../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml_as_hash_with_parse"]).to eq("Array[{ order: Nokogiri::XML::Node? }]")
    end

    it "resolves .map block with self method call" do
      code = File.read(File.join(__dir__, "../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml_as_hash"]).to eq("Array[{ date: Nokogiri::XML::Node?, order: Nokogiri::XML::Node }]")
    end

    it "does not modify non-map block calls" do
      code = File.read(File.join(__dir__, "../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml"]).to eq("Array[Nokogiri::XML::Node]")
    end
  end

  describe "#contracts_store" do
    # Regression: the bridge used to call Steep with `Steep::Contracts::Store.empty`,
    # so `Steep::TypeConstruction#contract_narrowed_type` never fired even when
    # the project had a `sig/generated/.steep_contracts.yml` describing
    # preconditions for the methods being analyzed. The bridge now loads the
    # sidecar on first access; `method_return_types` consumes it transparently.
    context "with the dummy app's sidecar present" do
      it "loads precondition contracts from sig/generated/.steep_contracts.yml" do
        store = bridge.send(:contracts_store)

        expect(store).to be_a(Steep::Contracts::Store)
        expect(store.empty?).to be false
      end

      it "exposes individual entries via lookup_instance" do
        store = bridge.send(:contracts_store)
        contract = store.lookup_instance("Comment", :author_name)

        expect(contract).not_to be_nil
        expect(contract.requires).not_to be_empty
      end

      it "memoizes the loaded store across calls" do
        first = bridge.send(:contracts_store)
        second = bridge.send(:contracts_store)

        expect(first).to equal(second)
      end
    end

    context "without a sidecar" do
      around do |example|
        Dir.mktmpdir do |tmp|
          Dir.chdir(tmp) { example.run }
        end
      end

      it "returns an empty store without raising" do
        fresh = described_class.new
        store = fresh.send(:contracts_store)

        expect(store).to be_a(Steep::Contracts::Store)
        expect(store.empty?).to be true
      end
    end

    context "with a malformed sidecar" do
      around do |example|
        Dir.mktmpdir do |tmp|
          dir = File.join(tmp, "sig", "generated")
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, ".steep_contracts.yml"), "not: valid: yaml:\n  - [unbalanced")
          Dir.chdir(tmp) { example.run }
        end
      end

      it "warns and falls back to an empty store" do
        fresh = described_class.new
        # The Steep loader catches Psych::SyntaxError internally and returns
        # Store.empty, so our rescue isn't exercised — but the path is still
        # safe and produces an empty store rather than blowing up.
        store = fresh.send(:contracts_store)

        expect(store).to be_a(Steep::Contracts::Store)
        expect(store.empty?).to be true
      end
    end
  end

  describe "#ivar_write_types" do
    # Cobertura da regra introduzida em felixefelip/rbs_infer#4:
    # coleta todas as escritas, deduplica, e adiciona `| nil` quando a
    # ivar não tem escrita garantida por construção (initialize ou
    # corpo da classe).

    it "collects single write inside initialize as non-nilable" do
      code = <<~RUBY
        class Foo
          def initialize
            @x = "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("String")
    end

    it "adds nil when ivar is written only in a non-initialize method" do
      code = <<~RUBY
        class Foo
          def set_x
            @x = "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("String?")
    end

    it "unions multiple distinct writes across non-initialize methods" do
      code = <<~RUBY
        class Foo
          def set_a
            @x = Comment.find(1)
          end

          def set_b
            @x = Comment.new
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("((Comment & Comment::Validated) | Comment)?")
    end

    it "unions writes and drops nil when initialize also writes" do
      code = <<~RUBY
        class Foo
          def initialize
            @x = Comment.new
          end

          def set_x
            @x = Comment.find(1)
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("Comment | (Comment & Comment::Validated)")
    end

    it "dedupes textually-equal writes" do
      code = <<~RUBY
        class Foo
          def set_a
            @x = Comment.find(1)
          end

          def set_b
            @x = Comment.find(2)
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("(Comment & Comment::Validated)?")
    end

    it "collects attr_writer self.x = expr as a write to @x" do
      code = <<~RUBY
        class Foo
          attr_writer :x

          def set_a
            self.x = "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("String?")
    end

    it "collects attr_accessor writes into the same union as direct ivasgn" do
      code = <<~RUBY
        class Foo
          attr_accessor :x

          def initialize
            @x = Comment.new
          end

          def update
            self.x = Comment.find(1)
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("Comment | (Comment & Comment::Validated)")
    end

    it "keeps non-nil when initialize uses attr_writer setter" do
      code = <<~RUBY
        class Foo
          attr_accessor :x

          def initialize
            self.x = "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("String")
    end

    it "explicit @x = nil adds nilability even when initialize writes" do
      code = <<~RUBY
        class Foo
          def initialize
            @x = "hello"
          end

          def clear
            @x = nil
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      expect(result["x"]).to eq("String?")
    end

    it "treats class-body @x = expr as initialized" do
      code = <<~RUBY
        class Foo
          @x = "hello"

          def update
            @x = "world"
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      # class-body ivasgn is class-instance variable scope; method
      # ivasgn is instance scope. Per the issue, we treat the class-body
      # write as initialized for the same name (best-effort).
      expect(result["x"]).to eq("String")
    end

    it "single non-initialize write of nil literal stays just nil-ish (returns nil token)" do
      code = <<~RUBY
        class Foo
          def reset
            @x = nil
          end
        end
      RUBY

      result = bridge.ivar_write_types(code)
      # Only `nil` was observed; nilable, no concrete type. The emitter
      # returns "nil" which is a valid RBS type.
      expect(result["x"]).to eq("nil")
    end
  end

  describe "#ivar_write_types_per_method" do
    # Per-method narrowing primitive — drives per-action ivar typing in
    # the ERB convention generator. Each method's contribution is kept
    # separate so consumers can union only the writers relevant to a
    # given context (action + before_action handlers, for example).

    it "groups ivar writes by enclosing method" do
      code = <<~RUBY
        class Foo
          def set_x
            @x = Comment.find(1)
          end

          def make_x
            @x = Comment.new
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      expect(result["set_x"]["x"]).to eq("(Comment & Comment::Validated)")
      expect(result["make_x"]["x"]).to eq("Comment")
    end

    it "unions multiple writes within the same method" do
      code = <<~RUBY
        class Foo
          def set_x
            @x = Comment.new
            @x = Comment.find(1)
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      expect(result["set_x"]["x"]).to eq("Comment | (Comment & Comment::Validated)")
    end

    it "captures attr_writer self.x = expr as a write to @x in the enclosing method" do
      code = <<~RUBY
        class Foo
          attr_writer :x

          def assign
            self.x = "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      expect(result["assign"]["x"]).to eq("String")
    end

    it "omits methods that don't write any ivar" do
      code = <<~RUBY
        class Foo
          def writes
            @x = "hello"
          end

          def no_write
            1 + 1
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      expect(result.keys).to eq(["writes"])
    end

    it "does NOT add | nil for methods that don't write the ivar" do
      # Distinct from `ivar_write_types` which adds `| nil` when no
      # writer is in `initialize`. The per-method primitive returns
      # the writer's raw contribution; nilability is the caller's
      # decision.
      code = <<~RUBY
        class Foo
          def set_x
            @x = "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      expect(result["set_x"]["x"]).to eq("String")
    end

    it "returns empty hash for source with no class body" do
      result = bridge.ivar_write_types_per_method("# just a comment")
      expect(result).to eq({})
    end

    it "ignores ivasgn outside any method (class-body scope)" do
      code = <<~RUBY
        class Foo
          @class_inst = "hello"

          def writes
            @inst = "world"
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      # `@class_inst` at class body is class-instance variable, not
      # attributable to a method.
      expect(result["writes"]["inst"]).to eq("String")
      expect(result["writes"]).not_to have_key("class_inst")
    end

    it "skips writes inside singleton methods" do
      code = <<~RUBY
        class Foo
          def self.set_x
            @x = "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      # `def self.X` operates on the singleton; ivars there are
      # class-instance variables, not relevant for the per-action
      # narrowing we serve.
      expect(result).to eq({})
    end
  end

  describe "#all_expression_types" do
    it "maps line:column to type for all typed expressions" do
      code = <<~RUBY
        class Foo
          def bar
            x = Comment.find(1)
          end
        end
      RUBY

      result = bridge.all_expression_types(code)
      expect(result).not_to be_empty
      # The lvasgn for x is on line 3
      typed_values = result.values
      expect(typed_values).to include("(Comment & Comment::Validated)")
    end

    it "returns empty hash for unparseable code" do
      result = bridge.all_expression_types("!!!invalid ruby")
      expect(result).to eq({})
    end
  end
end
