require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::SteepBridge::IvarWriteAnalyzer, :dummy_app do
  let(:bridge) { RbsInfer::Signatures::SteepBridge.new }

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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
      expect(result["x"]).to eq("String?")
    end

    # `@x ||= v` / `@x &&= v` are ivar writes too, but their AST parks the
    # name in an argument-less inner `:ivasgn` and the RHS one level up in an
    # `:or_asgn`/`:and_asgn`, so the collector used to walk past them and drop
    # the write entirely (felixefelip/rbs_infer#85).
    it "collects an `||=` memoization write (nilable, lazy by nature)" do
      code = <<~RUBY
        class Foo
          def cache
            @x ||= "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types(code, target_class: "Foo")
      expect(result["x"]).to eq("String?")
    end

    it "collects an `&&=` write" do
      code = <<~RUBY
        class Foo
          def guard
            @x &&= "hello"
          end
        end
      RUBY

      result = bridge.ivar_write_types(code, target_class: "Foo")
      expect(result["x"]).to eq("String?")
    end

    # `+=`/`<<=` are `InstanceVariableOperatorWriteNode` (`:op_asgn`): the
    # result type is the operator's, not the RHS's, so the RHS-intrinsic
    # approach doesn't apply. Left uncollected on purpose.
    it "does not mis-type an `+=` operator write from its RHS literal" do
      code = <<~RUBY
        class Foo
          def bump
            @count += 1
          end
        end
      RUBY

      result = bridge.ivar_write_types(code, target_class: "Foo")
      expect(result).not_to have_key("count")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types(code, target_class: "Foo")
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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

      expect(result["set_x"]["x"]).to eq("String")
    end

    it "returns empty hash for source with no class body" do
      result = bridge.ivar_write_types_per_method("# just a comment", target_class: "Foo")
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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

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

      result = bridge.ivar_write_types_per_method(code, target_class: "Foo")

      expect(result["set_default_name"]["name"]).to eq("String")
    end
  end

  describe "ivar-write class scoping (felixefelip/rbs_infer#38)" do
    # Two classes in one file that share a method name (`initialize`) and an
    # ivar name (`@shared`). Before scoping, both `ivar_write_types` and
    # `ivar_write_types_per_method` pooled writes across the classes.
    let(:code) do
      <<~RUBY
        class Alpha
          def initialize
            @shared = "a"
          end

          def touch
            @only_alpha = 1
          end
        end

        class Beta
          def configure
            @shared = 2
          end
        end
      RUBY
    end

    it "attributes per-method writes only to the requested class" do
      alpha = bridge.ivar_write_types_per_method(code, target_class: "Alpha")
      expect(alpha["initialize"]).to eq({ "shared" => "String" })
      expect(alpha["touch"]).to eq({ "only_alpha" => "Integer" })
      # Beta#configure must not appear under Alpha.
      expect(alpha).not_to have_key("configure")

      beta = bridge.ivar_write_types_per_method(code, target_class: "Beta")
      expect(beta["configure"]).to eq({ "shared" => "Integer" })
      # Alpha's `initialize`/`touch` must not merge into Beta.
      expect(beta.keys).to eq(["configure"])
    end

    it "scopes flat writes and the definite-initialization rule per class" do
      # `@shared` is initialized in Alpha#initialize (non-nil) but only
      # assigned in Beta#configure outside init — so it is nilable *for
      # Beta*. Without scoping, Alpha's initialize would suppress the `?`
      # and Alpha's "String" would merge in.
      alpha = bridge.ivar_write_types(code, target_class: "Alpha")
      expect(alpha["shared"]).to eq("String")

      beta = bridge.ivar_write_types(code, target_class: "Beta")
      expect(beta["shared"]).to eq("Integer?")
      expect(beta).not_to have_key("only_alpha")
    end

    # A nested class is its own target, so its writes are not the enclosing
    # class's. Scoping used to match any namespace under the target
    # (`start_with?("#{target}::")`), which is right for a nested *module*
    # (emitted in place by the owner mechanism, #22) but wrong for a class:
    # `@name` from `Outer::User#initialize` surfaced as `Outer`'s.
    context "com declarações aninhadas" do
      let(:nested_code) do
        <<~RUBY
          class Outer
            class User
              def initialize
                @name = "n"
              end
            end

            module Generated
              def configure
                @setting = 1
              end
            end

            def run
              @ran = true
            end
          end
        RUBY
      end

      it "não atribui os writes de uma classe aninhada à classe externa" do
        outer = bridge.ivar_write_types(nested_code, target_class: "Outer")

        expect(outer).not_to have_key("name")
      end

      it "atribui os writes de um módulo aninhado à classe externa" do
        outer = bridge.ivar_write_types(nested_code, target_class: "Outer")

        expect(outer).to have_key("setting")
        expect(outer).to have_key("ran")
      end

      it "atribui os writes da classe aninhada ao seu próprio alvo" do
        user = bridge.ivar_write_types(nested_code, target_class: "Outer::User")

        expect(user).to have_key("name")
        expect(user).not_to have_key("ran")
      end
    end
  end
end
