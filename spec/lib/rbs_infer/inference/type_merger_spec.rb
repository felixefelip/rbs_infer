require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::TypeMerger do
  let(:merger) { described_class.new(target_file: nil, constant_resolver: fake_constant_resolver) }

  it "prioriza tipos resolvidos sobre untyped" do
    usages = [
      { "nome" => "String", "email" => "untyped" },
      { "nome" => "String", "email" => "String" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["nome"]).to eq("String")
    expect(result["email"]).to eq("String")
  end

  it "gera union type quando há tipos diferentes" do
    usages = [
      { "value" => "String" },
      { "value" => "Integer" },
    ]

    result = merger.merge_argument_types(usages)
    expect(result["value"]).to eq("(String | Integer)")
  end

  it "normaliza :: prefix e deduplica" do
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
  end

  describe "#resolve_method_return_types_from_attrs" do
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
      allow(resolver).to receive(:resolve).with("Session", "signed_id").and_return("String")

      merger.resolve_method_return_types_from_attrs(
        collector.members,
        {},
        method_type_resolver: resolver,
        parsed_target: parsed_target,
        method_param_types: { "set_current_session" => { "session" => "Session" } }
      )

      expect(member.signature).to end_with("-> { value: String, httponly: bool, same_site: Symbol }")
    end

    # The "não corrompe assinatura..." spec below only inspects what
    # ClassMemberCollector produced — it never reaches
    # `resolve_method_return_types_from_attrs`, where the return type is actually
    # substituted. This one drives that path.
    it "preserva o bloco ao refinar o record de uma atribuição indexada" do
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
      expect(member.signature).to include("?{ (untyped) -> untyped } -> untyped")

      resolver = instance_double("MethodTypeResolver")
      allow(resolver).to receive(:resolve).with("Session", "signed_id").and_return("String")

      merger.resolve_method_return_types_from_attrs(
        collector.members,
        {},
        method_type_resolver: resolver,
        parsed_target: parsed_target,
        method_param_types: { "write" => { "session" => "Session" } }
      )

      # The BLOCK's `-> untyped` has to survive; only the final return changes.
      expect(member.signature)
        .to eq("write: (untyped session) ?{ (untyped) -> untyped } -> { value: String, httponly: bool }")
    end

    it "não corrompe assinatura de método com bloco ao resolver return type" do
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
      # Signature should have block: "wrapper: () ?{ (untyped) -> untyped } -> String"
      # The block's -> untyped should NOT be replaced
      expect(member.signature).to include("?{ (untyped) -> untyped } -> String")
      expect(member.signature).not_to include("-> untyped } -> String } -> String")
    end
  end
end
