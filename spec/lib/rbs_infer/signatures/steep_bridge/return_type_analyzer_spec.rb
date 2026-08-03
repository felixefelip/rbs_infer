require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::SteepBridge::ReturnTypeAnalyzer, :dummy_app do
  subject(:bridge) { RbsInfer::Signatures::SteepBridge.new }

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
      code = File.read(File.join(__dir__, "../../../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml_as_hash_with_parse"]).to eq("Array[{ order: Nokogiri::XML::Node? }]")
    end

    it "resolves .map block with self method call" do
      code = File.read(File.join(__dir__, "../../../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml_as_hash"]).to eq("Array[{ date: Nokogiri::XML::Node?, order: Nokogiri::XML::Node }]")
    end

    it "does not modify non-map block calls" do
      code = File.read(File.join(__dir__, "../../../../dummy/app/services/tag_destroy.rb"))
      result = bridge.method_return_types(code)
      expect(result["parse_xml"]).to eq("Array[Nokogiri::XML::Node]")
    end
  end
end
