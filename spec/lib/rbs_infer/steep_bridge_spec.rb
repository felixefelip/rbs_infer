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

    # Regression for the `User::Idade#idade` => `() -> untyped` bug.
    #
    # Gem RBS (e.g. activesupport) reopens core stdlib classes with
    # overload-extending signatures, e.g. on `::Date`:
    #
    #     def +: (ActiveSupport::Duration other) -> self
    #          | ...   # extends the stdlib Date#+ overloads
    #
    # The trailing `| ...` needs the stdlib `date` base method to exist.
    # The bridge used to load only `.gem_rbs_collection/*/*/` (gem RBS,
    # no stdlib), so building `::Date`'s method table raised
    # `RBS::InvalidOverloadMethodError`, Steep wrapped it as an
    # `UnexpectedError`, and every `Date`-receiver expression collapsed
    # to `untyped` — poisoning the whole arithmetic chain. Loading the
    # collection lockfile (which lists `date`/`time` as `type: stdlib`)
    # brings in the base definitions and keeps the bridge in parity with
    # `steep check`.
    context "Date/stdlib-backed chains (collection lockfile loading)" do
      it "types a Date arithmetic chain ending in #to_f as Float, not untyped" do
        code = <<~RUBY
          class Comment
            def age_in_years
              ((Date.today - Date.today) / 365).to_f
            end
          end
        RUBY

        result = bridge.method_return_types(code)
        expect(result["age_in_years"]).to eq("Float")
      end

      it "types the reported User::Idade#idade chain (.to_f.truncate(2))" do
        code = <<~RUBY
          class Comment
            def idade
              ((Date.today - Date.today) / 365).to_f.truncate(2)
            end
          end
        RUBY

        result = bridge.method_return_types(code)
        # The essential guarantee is that it is no longer `untyped`
        # (absent from the result). `Float#truncate(ndigits)` is declared
        # to return `(Integer | Float)` because the type system can't see
        # that `2 > 0`.
        expect(result).to have_key("idade")
        expect(result["idade"]).to eq("(Integer | Float)")
      end
    end

    it "returns empty hash for unparseable code" do
      result = bridge.method_return_types("!!!invalid ruby")
      expect(result).to eq({})
    end

    # felixefelip/rbs_infer#33: `def x` and `def self.x` used to write the
    # same name-keyed entry, so one clobbered the other.
    it "keeps instance and singleton methods sharing a name in separate maps" do
      code = <<~RUBY
        class Foo
          def self.tally
            "big"
          end

          def tally
            42
          end
        end
      RUBY

      by_kind = bridge.method_return_types_by_kind(code)
      expect(by_kind[:singleton]["tally"]).to eq("String")
      expect(by_kind[:instance]["tally"]).to eq("Integer")
      # The name-keyed accessor returns instance methods only.
      expect(bridge.method_return_types(code)["tally"]).to eq("Integer")
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

  describe "#callback_self_types" do
    # Reads the `applies_self` callback sidecar (.steep_callbacks.yml,
    # felixefelip/steep#27) so call-site inference can resolve `self`
    # inside an after-validation callback to the validated record type.
    # The dummy's sidecar declares `Comment#notify_post_author` →
    # `Comment & Comment::Validated`.
    it "maps callback handler methods to their refined self type" do
      result = bridge.callback_self_types("Comment")
      expect(result["notify_post_author"]).to eq("Comment & Comment::Validated")
    end

    it "normalizes a leading :: in the class name" do
      expect(bridge.callback_self_types("::Comment")).to eq(bridge.callback_self_types("Comment"))
    end

    it "returns an empty hash for a class with no callback entries" do
      expect(bridge.callback_self_types("Foo")).to eq({})
    end

    it "returns an empty hash for nil" do
      expect(bridge.callback_self_types(nil)).to eq({})
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

    it "reads RHS type rather than the :ivasgn type so LHS-widening doesn't mask narrowings" do
      # When the ivar is declared via attr_accessor with a nilable
      # type, Steep widens the :ivasgn node's type to the declared
      # type. Reading the RHS directly preserves the writer's actual
      # contribution — matching what Steep's own
      # `Postconditions::Inferrer` does and unblocking marker
      # synthesis in steady state.
      code = <<~RUBY
        class Foo
          attr_accessor :name #: String?

          def initialize(name: nil)
            @name = name
          end

          def clear_name
            @name = nil
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      # `nil` literal isn't context-widened (it's already the bottom
      # of the union), so this test catches LHS-widening regressions
      # specifically: if the code reverts to reading `:ivasgn` type,
      # the result here would be `String?` instead of `nil`.
      expect(result["clear_name"]["name"]).to eq("nil")
    end

    it "uses literal's intrinsic type when ivar is declared nilable in RBS" do
      # Even reading the RHS still gives the WIDENED type because
      # Steep's `:ivasgn` synthesize passes the LHS declared type as
      # `hint:` to RHS synthesize, and `test_literal_type` returns the
      # hint when the literal is compatible. `intrinsic_type_of`
      # bypasses hint propagation for literal nodes (mirrors the same
      # fix in Steep's `Postconditions::Inferrer`,
      # felixefelip/steep#35).
      #
      # Without the fix, `@name = "TBA"` against declared `String?`
      # types as `String?` — narrowing detection misses it and the
      # SetterMarkerSynthesizer never emits `AfterSetDefaultName`.
      code = <<~RUBY
        class Foo
          attr_accessor :name #: String?

          def initialize(name: nil)
            @name = name
          end

          def set_default_name
            @name = "TBA"
          end
        end
      RUBY

      result = bridge.ivar_write_types_per_method(code)

      expect(result["set_default_name"]["name"]).to eq("String")
    end
  end

  describe "#constant_types" do
    it "tipa constantes literais pelo RHS" do
      code = <<~RUBY
        class Foo
          MAX = 8
          DEFAULT_NAME = "Blue"
        end
      RUBY

      result = bridge.constant_types(code)
      expect(result["MAX"]).to eq("Integer")
      expect(result["DEFAULT_NAME"]).to eq("String")
    end

    it "infere o tipo de elemento de literais de array" do
      code = <<~RUBY
        class Foo
          WEIGHTS = [1, 2, 3]
        end
      RUBY

      expect(bridge.constant_types(code)["WEIGHTS"]).to eq("Array[Integer]")
    end

    it "chaveia constantes de path pelo nome puro (casgn)" do
      code = <<~RUBY
        class Foo
        end
        Foo::LIMIT = 100
      RUBY

      expect(bridge.constant_types(code)["LIMIT"]).to eq("Integer")
    end

    it "omite constantes cujo RHS é untyped" do
      code = <<~RUBY
        class Foo
          UNKNOWN = some_runtime_call
        end
      RUBY

      expect(bridge.constant_types(code)).not_to have_key("UNKNOWN")
    end

    it "retorna hash vazio para código inválido" do
      expect(bridge.constant_types("!!!invalid ruby")).to eq({})
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
