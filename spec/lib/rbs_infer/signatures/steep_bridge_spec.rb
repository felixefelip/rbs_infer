require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::SteepBridge, :dummy_app do
  subject(:bridge) { described_class.new }

  describe "#local_var_read_types" do
    # felixefelip/rbs_infer#142. The per-method map holds one type per variable
    # and so cannot express narrowing; the per-read map is where Steep's
    # narrowing actually lives.
    it "gives the narrowed type at a read the per-method map reports as nilable" do
      code = <<~RUBY
        class Foo
          def bar
            if user = User.where(active: true).first
              puts user
            end
          end
        end
      RUBY

      expect(bridge.local_var_types_per_method(code)["bar"]["user"])
        .to eq("(User & User::Validated)?")

      reads = bridge.local_var_read_types(code)
      expect(reads.values).to include("(User & User::Validated)")
      expect(reads.values).not_to include("(User & User::Validated)?")
    end

    it "keys by line and character column" do
      code = <<~RUBY
        class Foo
          def bar
            user = User.where(active: true).first
            puts user
          end
        end
      RUBY

      reads = bridge.local_var_read_types(code)
      # `puts user` on line 4, `user` starting at column 9 (0-based).
      expect(reads[[4, 9]]).to eq("(User & User::Validated)?")
    end
  end

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

  describe "#postcondition_established_ivars" do
    # Reads the postconditions sidecar so call-site inference can use a FLOW
    # fact the analyzer cannot derive: a controller's declared `@post` is
    # nilable (assigned in `set_post`, not in `initialize`), but past the
    # `set_post` call it is narrowed. The dummy's sidecar declares
    # `PostsController#set_post` → `@post: (::Post & ::Post::Validated)`.
    it "maps a method to the ivars it proves populated" do
      result = bridge.postcondition_established_ivars("PostsController")

      expect(result["set_post"]).to eq("@post" => "(::Post & ::Post::Validated)")
    end

    it "keys ivars with the `@`, matching how Prism names an ivar read" do
      result = bridge.postcondition_established_ivars("PostsController")

      expect(result["set_post"].keys).to all(start_with("@"))
    end

    it "normalizes a leading :: in the class name" do
      expect(bridge.postcondition_established_ivars("::PostsController"))
        .to eq(bridge.postcondition_established_ivars("PostsController"))
    end

    it "omits methods whose postcondition establishes no ivar" do
      # An entry can carry only a `self:` refinement or a returns-establishment;
      # those say nothing about an ivar and must not appear as an empty map.
      result = bridge.postcondition_established_ivars("PostsController")

      expect(result.values).to all(satisfy { |ivars| !ivars.empty? })
    end

    it "returns an empty hash for a class with no entries" do
      expect(bridge.postcondition_established_ivars("Foo")).to eq({})
    end

    it "returns an empty hash for nil" do
      expect(bridge.postcondition_established_ivars(nil)).to eq({})
    end
  end

  describe "#argument_entry_partitions" do
    # Argument-sensitive partitions (felixefelip/steep#89, #91, #95): per (method,
    # parameter, literal), what the callers passing that literal had established. The
    # dummy's controller-runtime `render` override dispatches `case target when :edit`.
    it "maps a method to its per-literal partitions" do
      result = bridge.argument_entry_partitions("PostsController")

      edit = result["render"].find { |p| p[:pattern] == ":edit" }
      expect(edit).not_to be_nil
      expect(edit[:param]).to eq("target")
      expect(edit[:ivars]["@post"]).to eq("::Post & ::Post::Validated")
    end

    it "keeps each literal's partition separate" do
      result = bridge.argument_entry_partitions("PostsController")

      new_partition = result["render"].find { |p| p[:pattern] == ":new" }
      expect(new_partition[:ivars]["@post"]).to eq("::Post")
    end

    it "normalizes a leading :: in the class name" do
      expect(bridge.argument_entry_partitions("::PostsController"))
        .to eq(bridge.argument_entry_partitions("PostsController"))
    end

    it "returns an empty result for a class with no partitions" do
      expect(bridge.argument_entry_partitions("Foo")).to be_empty
    end

    it "returns an empty result for nil" do
      expect(bridge.argument_entry_partitions(nil)).to eq({})
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

  # The two env-backed constant lookups, pinned directly rather than through the
  # snapshots they feed. Both answer "no" by returning nil/false, so anything that
  # breaks the environment access — the class method moving, say — reads as "this
  # constant is not a class" and every `?Klass` default quietly becomes `?untyped`,
  # eight snapshots away from the cause.
  describe "env-backed constant lookups" do
    it "recognizes a class of the project as a class" do
      expect(bridge.class_or_module?("Palette", namespace: nil)).to be(true)
      expect(bridge.class_or_module?("Post", namespace: nil)).to be(true)
    end

    it "says no for a name that is not a class" do
      expect(bridge.class_or_module?("NoSuchConstantAnywhere", namespace: nil)).to be(false)
    end

    it "reads a constant's declared type out of the environment" do
      # `sig/` of the dummy declares it; a class reference has no `casgn` and so
      # is absent here by design — that is `class_or_module?`'s question.
      expect(bridge.constant_type_from_env("Post", namespace: nil)).to be_nil
    end

    # `RBS::TypeName.parse` raises a bare RuntimeError on a string that is no
    # constant path at all, and a caller can hand one over. Skipping that
    # candidate is the only failure either lookup absorbs — everything else
    # raised in there is a bug and must surface.
    it "skips a candidate that is not a constant path" do
      expect(bridge.class_or_module?("", namespace: nil)).to be(false)
      expect(bridge.constant_type_from_env("", namespace: nil)).to be_nil
      expect(bridge.class_or_module?("Post", namespace: "")).to be(true)
    end
  end

  describe "#all_expression_types" do
    it "maps every typed expression to its type" do
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

    # felixefelip/rbs_infer#168. A receiver starts exactly where its call does,
    # so three expressions here begin at 3:4 and only the range tells them
    # apart. Keyed by the start alone they collapsed into one entry, and the
    # answer the caller-side inference read was whichever `each_typing` yielded
    # last — the receiver, whenever the call itself was `untyped`.
    it "keys an expression by its whole range, so a receiver cannot answer for its call" do
      code = <<~RUBY
        class Foo
          def bar
            Comment.find(1).body
          end
        end
      RUBY

      result = bridge.all_expression_types(code)

      expect(result["3:4-3:11"]).to eq("singleton(Comment)")
      expect(result["3:4-3:19"]).to eq("(Comment & Comment::Validated)")
      expect(result["3:4-3:24"]).to eq("String")
    end

    it "returns empty hash for unparseable code" do
      result = bridge.all_expression_types("!!!invalid ruby")
      expect(result).to eq({})
    end
  end

  # Type-check results and the sidecar stores depend on (source, env, stores) —
  # never on the target class — so they are shared across bridges rather than
  # rebuilt per analysis. What makes that safe is the key: the Steep context,
  # which `SteepEnvironment.reset!` replaces.
  describe "sharing across bridges" do
    it "hands two bridges the same sidecar store" do
      expect(described_class.new.send(:contracts_store))
        .to equal(described_class.new.send(:contracts_store))
    end

    it "hands two bridges the same type-check result" do
      source = "class SharedProbe\n  def go = 1\nend\n"

      expect(described_class.new.type_check(source))
        .to equal(described_class.new.type_check(source))
    end

    it "buckets everything under one context, so one key invalidates all of it" do
      context = RbsInfer::Signatures::SteepEnvironment.steep_context
      bucket = described_class.shared(context)

      expect(described_class.shared(context)).to equal(bucket)
      expect(bucket.keys).to contain_exactly(:type_checks, :sidecars)
    end

    # The reason there is no second `reset!` to call: the bucket is keyed on the
    # context object, so dropping the environment drops what was computed
    # against it. A result must never outlive the RBS it was derived from.
    it "drops the shared bucket when the environment is reset" do
      before_reset = described_class.shared(RbsInfer::Signatures::SteepEnvironment.steep_context)

      RbsInfer::Signatures::SteepEnvironment.reset!
      after_reset = described_class.shared(RbsInfer::Signatures::SteepEnvironment.steep_context)

      expect(after_reset).not_to equal(before_reset)
      expect(after_reset[:type_checks]).to be_empty
      expect(after_reset[:sidecars]).to be_empty
    end
  end

  # felixefelip/rbs_infer#191. The relation `Ruby::MethodBodyTypeMismatch`
  # reports on, asked of Steep's own check so a generated signature can be
  # corrected exactly when the checker would reject it.
  describe "#accepts?" do
    it "answers true for a body type the declaration covers" do
      expect(bridge.accepts?("String", "String")).to be(true)
      expect(bridge.accepts?("(String | Array[String])", "String")).to be(true)
      expect(bridge.accepts?("String?", "String")).to be(true)
    end

    it "answers false for a body type the declaration does not cover" do
      expect(bridge.accepts?("String", "(String | Array[String])")).to be(false)
      expect(bridge.accepts?("String", "Integer")).to be(false)
    end

    # Signatures write relative names; the definitions are filed under absolute
    # ones. Without absolutizing, every project type would be undecidable.
    it "resolves a relative name to the project's definition" do
      expect(bridge.accepts?("ApplicationRecord", "User")).to be(true)
      expect(bridge.accepts?("User", "ApplicationRecord")).to be(false)
    end

    # `nil` is "cannot decide", which a caller must not read as "does not
    # accept" — `self` names the enclosing definition, and there is none here.
    it "answers nil for a type it cannot compare" do
      expect(bridge.accepts?("self", "User")).to be_nil
      expect(bridge.accepts?("Array[self]", "Array[User]")).to be_nil
      expect(bridge.accepts?("String", "not a type[")).to be_nil
    end
  end
end
