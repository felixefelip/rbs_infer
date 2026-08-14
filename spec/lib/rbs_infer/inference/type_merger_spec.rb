require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::TypeMerger do
  let(:merger) { described_class.new(target_file: nil, constant_resolver: fake_constant_resolver) }

  it "prioritises resolved types over untyped" do
    usages = [
      { "nome" => "String", "email" => "untyped" },
      { "nome" => "String", "email" => "String" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["nome"]).to eq("String")
    expect(result["email"]).to eq("String")
  end

  it "builds a union type when the types differ" do
    usages = [
      { "value" => "String" },
      { "value" => "Integer" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["value"]).to eq("(String | Integer)")
  end

  it "normalises the :: prefix and deduplicates" do
    usages = [
      { "cpf" => "::Shared::Cpf" },
      { "cpf" => "Shared::Cpf" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["cpf"]).to eq("Shared::Cpf")
  end

  describe ".union_types" do
    it "unions distinct types preserving the original form" do
      expect(described_class.union_types(["String", "::MyApp::Entity"]))
        .to eq("(String | ::MyApp::Entity)")
    end

    it "emits a single type verbatim (keeps the absolute `::`)" do
      expect(described_class.union_types(["::MyApp::Entity"])).to eq("::MyApp::Entity")
    end

    it "flattens pre-existing unions instead of nesting parens" do
      expect(described_class.union_types(["(String | Symbol)", "Symbol"]))
        .to eq("(String | Symbol)")
    end

    it "does not flatten a `|` nested inside generics" do
      expect(described_class.union_types(["Array[String | Symbol]"]))
        .to eq("Array[String | Symbol]")
    end

    it "drops untyped when at least one resolved type exists" do
      expect(described_class.union_types(["untyped", "String"])).to eq("String")
    end

    # The same intersection arrives parenthesized when read back from an RBS declaration
    # and bare from Steep. A textual key made them two members of a bogus union.
    it "collapses two spellings of the same type" do
      expect(described_class.union_types(["(Post & Post::Validated)", "Post & Post::Validated"]))
        .to eq("(Post & Post::Validated)")
    end

    it "collapses spellings differing only in the absolute prefix" do
      expect(described_class.union_types(["User & ::User::Validated", "(::User & ::User::Validated)"]))
        .to eq("User & ::User::Validated")
    end

    # The two branches of a call on a nilable receiver answer with opposite
    # constants (`Model#present?: () -> true` / `NilClass#present?: () -> false`),
    # so the union that spans them is the whole of `bool` and should say so.
    it "collapses the two boolean constants into bool" do
      expect(described_class.union_types(["true", "false"])).to eq("bool")
    end

    it "drops a boolean constant bool already covers" do
      expect(described_class.union_types(["bool", "false"])).to eq("bool")
    end

    it "keeps nil alongside the collapsed bool" do
      expect(described_class.union_types(["true", "false", "nil"])).to eq("(bool | nil)")
    end

    # `NilClass#to_s: () -> ""` against any other branch's `String`.
    it "drops a literal its own class already covers" do
      expect(described_class.union_types(["String", '""'])).to eq("String")
      expect(described_class.union_types([":a", "Symbol"])).to eq("Symbol")
    end

    it "keeps a literal whose class is not in the union" do
      expect(described_class.union_types(['""', "Symbol"])).to eq('("" | Symbol)')
    end
  end

  describe "#resolve_method_return_types_from_attrs" do
    # A factory written in `class << self` ends in a BARE `new`, and that used
    # to fall past the constructor rule into the receiverless-call case, which
    # asks the name map — where `new` only appears once the class has an RBS of
    # its OWN. On a first generation there is none, so the method was left
    # `untyped` for Steep, and Steep is blind for the same reason: it resolved
    # `new` against `::Object` and typed the factory `Object`. Nothing ever
    # re-derived it, because every later pass only reconsiders members still
    # `untyped` — so `-> Object?` outlived the run that guessed it, and
    # deleting the `.rbs` to regenerate reproduced it rather than fixing it.
    #
    # No `method_type_resolver` here on purpose: the point is that the answer
    # comes from the source alone, with no RBS in the picture.
    it "types a bare `new` in a class-method body as the class being generated" do
      source = <<~RUBY
        class Digest
          class << self
            def for(post)
              new(post.title)
            end
          end

          def initialize(title)
            @title = title
          end
        end
      RUBY
      result = Prism.parse(source)
      parsed_target = RbsInfer::ParsedFile.new(result: result, source: source, comments: result.comments, lines: source.lines)
      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: result.comments, lines: source.lines)
      result.value.accept(collector)
      member = collector.members.find { |candidate| candidate.name == "for" }
      expect(member.kind).to eq(:class_method)

      described_class
        .new(target_file: nil, constant_resolver: fake_constant_resolver, target_class: "Digest")
        .resolve_method_return_types_from_attrs(collector.members, {}, parsed_target: parsed_target)

      expect(member.signature).to end_with("-> Digest")
    end

    # The mirror. In an INSTANCE method `self` is not the class, so a
    # receiverless `new` is an ordinary method call — answering `Digest` there
    # would invent a constructor the class does not have.
    it "leaves a bare `new` in an instance-method body alone" do
      source = <<~RUBY
        class Digest
          def rebuild
            new(@title)
          end
        end
      RUBY
      result = Prism.parse(source)
      parsed_target = RbsInfer::ParsedFile.new(result: result, source: source, comments: result.comments, lines: source.lines)
      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: result.comments, lines: source.lines)
      result.value.accept(collector)
      member = collector.members.find { |candidate| candidate.name == "rebuild" }

      described_class
        .new(target_file: nil, constant_resolver: fake_constant_resolver, target_class: "Digest")
        .resolve_method_return_types_from_attrs(collector.members, {}, parsed_target: parsed_target)

      expect(member.signature).to end_with("-> untyped")
    end

    # `@x = value` evaluates to VALUE. The ivar map cannot answer for a
    # SINGLETON setter — `self.@user` is a class-instance variable, a different
    # slot from the instance ivars this pass receives — which is why every
    # singleton setter in the dummy read `-> untyped` (felixefelip/rbs_infer#154).
    it "types a singleton setter from the parameter it assigns" do
      source = <<~RUBY
        class Registry
          def self.user=(value)
            @user = value
          end
        end
      RUBY
      result = Prism.parse(source)
      parsed_target = RbsInfer::ParsedFile.new(result: result, source: source, comments: result.comments, lines: source.lines)
      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: result.comments, lines: source.lines)
      result.value.accept(collector)
      member = collector.members.find { |candidate| candidate.name == "user=" }

      merger.resolve_method_return_types_from_attrs(
        collector.members,
        {},
        parsed_target: parsed_target,
        method_param_types: { "user=" => { "value" => "User" } }
      )

      expect(member.signature).to end_with("-> User")
    end

    # Narrow on purpose: anything but a bare parameter read is someone else's
    # question, and `untyped` is the honest answer rather than a guess.
    it "leaves a setter whose assignment is computed alone" do
      source = <<~RUBY
        class Registry
          def self.user=(value)
            @user = normalize(value)
          end
        end
      RUBY
      result = Prism.parse(source)
      parsed_target = RbsInfer::ParsedFile.new(result: result, source: source, comments: result.comments, lines: source.lines)
      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: result.comments, lines: source.lines)
      result.value.accept(collector)
      member = collector.members.find { |candidate| candidate.name == "user=" }

      merger.resolve_method_return_types_from_attrs(
        collector.members,
        {},
        parsed_target: parsed_target,
        method_param_types: { "user=" => { "value" => "User" } }
      )

      expect(member.signature).to end_with("-> untyped")
    end

    it "refines record fields in the RHS of an indexed assignment" do
      source = <<~RUBY
        class CookieWriter
          def set_current_session(session)
            cookies[:session_token] = { value: session.signed_id, httponly: true, same_site: :lax }
          end
        end
      RUBY
      result = Prism.parse(source)
      parsed_target = RbsInfer::ParsedFile.new(result: result, source: source, comments: result.comments, lines: source.lines)
      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: result.comments, lines: source.lines)
      result.value.accept(collector)
      member = collector.members.find { |candidate| candidate.name == "set_current_session" }
      resolver = instance_double("MethodTypeResolver")
      allow(resolver).to receive(:resolve).with("Session", "signed_id", arg_types: nil).and_return("String")

      merger.resolve_method_return_types_from_attrs(
        collector.members,
        {},
        method_type_resolver: resolver,
        parsed_target: parsed_target,
        method_param_types: { "set_current_session" => { "session" => "Session" } }
      )

      expect(member.signature).to end_with("-> { value: String, httponly: bool, same_site: Symbol }")
    end

    # The "does not corrupt a block-bearing signature..." spec below only
    # inspects what
    # ClassMemberCollector produced — it never reaches
    # `resolve_method_return_types_from_attrs`, where the return type is actually
    # substituted. This one drives that path.
    it "preserves the block when refining the record of an indexed assignment" do
      source = <<~RUBY
        class CookieWriter
          def write(session, &block)
            cookies[:session_token] = { value: session.signed_id, httponly: true }
          end
        end
      RUBY
      result = Prism.parse(source)
      parsed_target = RbsInfer::ParsedFile.new(result: result, source: source, comments: result.comments, lines: source.lines)
      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: result.comments, lines: source.lines)
      result.value.accept(collector)
      member = collector.members.find { |candidate| candidate.name == "write" }
      expect(member.signature).to include("?{ (*untyped) -> untyped } -> untyped")

      resolver = instance_double("MethodTypeResolver")
      allow(resolver).to receive(:resolve).with("Session", "signed_id", arg_types: nil).and_return("String")

      merger.resolve_method_return_types_from_attrs(
        collector.members,
        {},
        method_type_resolver: resolver,
        parsed_target: parsed_target,
        method_param_types: { "write" => { "session" => "Session" } }
      )

      # The BLOCK's `-> untyped` has to survive; only the final return changes.
      expect(member.signature)
        .to eq("write: (untyped session) ?{ (*untyped) -> untyped } -> { value: String, httponly: bool }")
    end

    it "does not corrupt a block-bearing signature when resolving the return type" do
      source = <<~RUBY
        class Foo
          def wrapper(&block)
            "hello"
          end
        end
      RUBY

      result = Prism.parse(source)
      comments = result.comments
      lines = source.lines

      collector = RbsInfer::Inference::ClassMemberCollector.new(comments: comments, lines: lines)
      result.value.accept(collector)

      member = collector.members.find { |m| m.name == "wrapper" }
      # Signature should have block: "wrapper: () ?{ (*untyped) -> untyped } -> String"
      # The block's -> untyped should NOT be replaced
      expect(member.signature).to include("?{ (*untyped) -> untyped } -> String")
      expect(member.signature).not_to include("-> untyped } -> String } -> String")
    end
  end
end
