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

    # felixefelip/rbs_infer#162. The third spelling of a class method, and the
    # node type does not tell it apart: inside `class << self` it is a plain
    # `:def`. Filed as an instance method it became unreachable, because the
    # reader asks by the member's kind — which is `:class_method`.
    it "files a `class << self` def as a singleton method" do
      code = <<~RUBY
        class Foo
          class << self
            def tally
              "big"
            end
          end

          def tally
            42
          end
        end
      RUBY

      by_kind = bridge.method_return_types_by_kind(code)
      expect(by_kind[:singleton]["tally"]).to eq("String")
      expect(by_kind[:instance]["tally"]).to eq("Integer")
    end

    # `class << obj` opens THAT object's singleton class, so its methods are
    # not the enclosing class's.
    it "leaves a `class << other` def where it was" do
      code = <<~RUBY
        class Foo
          OTHER = Object.new

          class << OTHER
            def tally
              "big"
            end
          end
        end
      RUBY

      expect(bridge.method_return_types_by_kind(code)[:singleton]).not_to have_key("tally")
    end

    # A class body inside the singleton class is out of it again.
    it "stops at a nested class body" do
      code = <<~RUBY
        class Foo
          class << self
            class Inner
              def tally
                42
              end
            end
          end
        end
      RUBY

      by_kind = bridge.method_return_types_by_kind(code)
      expect(by_kind[:instance]["tally"]).to eq("Integer")
      expect(by_kind[:singleton]).not_to have_key("tally")
    end
  end

  describe "#method_return_types block generic resolution" do
    it "resolves .map block body type when Steep returns Array[untyped]" do
      code = File.read(File.join(__dir__, "../../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml_as_hash_with_parse"]).to eq("Array[{ order: Nokogiri::XML::Node? }]")
    end

    it "resolves .map block with self method call" do
      code = File.read(File.join(__dir__, "../../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml_as_hash"]).to eq("Array[{ date: Nokogiri::XML::Node?, order: Nokogiri::XML::Node }]")
    end

    it "does not modify non-map block calls" do
      code = File.read(File.join(__dir__, "../../../dummy/app/services/tag_destroy.rb"))
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

  # The Steep type-checking context (subtyping + constant resolver, holding the
  # per-type method-shape cache) is shared at the class level so every Analyzer
  # reuses it instead of rebuilding shapes per file (felixefelip/rbs_infer#47).
  describe ".steep_context" do
    after { described_class.reset! }

    it "is memoized — the same context object across instances and calls" do
      ctx = described_class.steep_context
      expect(ctx).to be(described_class.steep_context)
      expect(described_class.new.steep_subtyping).to be(ctx[:subtyping])
      expect(described_class.new.steep_subtyping).to be(described_class.new.steep_subtyping)
    end

    it "is rebuilt after reset! (env may have changed between levels)" do
      before_ctx = described_class.steep_context
      described_class.reset!
      expect(described_class.steep_context).not_to be(before_ctx)
    end
  end
end
