require "spec_helper"
require "rbs_infer"
require "rbs"

RSpec.describe RbsInfer::Signatures::RbsParserUtil do
  describe ".class_info_from_rbs" do
    # felixefelip/rbs_infer#111: instance-variable members used to be parsed and
    # dropped, so a call site passing `@post` had nothing to resolve against even
    # though the class's own RBS stated the type.
    it "extrai tipos de instance variables, com o `@`" do
      rbs = <<~RBS
        class View
          @post: Post
          @count: Integer
          def render: () -> void
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "View")

      expect(info.ivar_types).to eq("@post" => "Post", "@count" => "Integer")
    end

    it "ignora instance variable declarada como untyped" do
      rbs = <<~RBS
        class View
          @post: untyped
        end
      RBS

      expect(described_class.class_info_from_rbs(rbs, "View").ivar_types).to be_empty
    end

    it "não confunde instance variable com attr_reader de mesmo nome" do
      # `attr_reader post: Post` is a METHOD (`types`); `@post: Post` is the ivar
      # slot. They are keyed separately so a reader never masks the ivar lookup.
      rbs = <<~RBS
        class View
          @post: Post
          attr_reader post: String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "View")

      expect(info.ivar_types).to eq("@post" => "Post")
      expect(info.types).to include("post" => "String")
    end

    it "extrai informações de classe simples" do
      rbs = <<~RBS
        class User
          def name: () -> String
          def self.find: (Integer) -> User
          include Comparable
          attr_reader email: String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "User")

      expect(info).to be_a(RbsInfer::Signatures::RbsClassInfo)
      expect(info.types).to include("name" => "String")
      expect(info.class_method_types).to include("find" => "User")
      expect(info.includes).to include("Comparable")
      expect(info.types).to include("email" => "String")
    end

    it "extrai superclass" do
      rbs = <<~RBS
        class Admin < User
          def role: () -> String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin")

      expect(info.superclass).to eq("User")
      expect(info.types).to eq("role" => "String")
    end

    it "encontra classe dentro de módulo aninhado" do
      rbs = <<~RBS
        module Admin
          class User
            def name: () -> String
          end
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin::User")

      expect(info.types).to eq("name" => "String")
    end

    it "encontra classe com namespace inline" do
      rbs = <<~RBS
        class Admin::User
          def name: () -> String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin::User")

      expect(info.types).to eq("name" => "String")
    end

    it "encontra módulo e seus métodos" do
      rbs = <<~RBS
        module Searchable
          def search: (String query) -> Array[self]
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Searchable")

      expect(info.types).to include("search")
    end

    it "retorna RbsClassInfo vazio quando classe não encontrada" do
      rbs = <<~RBS
        class Other
          def x: () -> void
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to be_empty
      expect(info.superclass).to be_nil
    end

    it "extrai attr_reader com tipo" do
      rbs = <<~RBS
        class Foo
          attr_reader name: String
          attr_reader count: Integer
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to include("name" => "String", "count" => "Integer")
    end

    it "ignora attr_reader untyped" do
      rbs = <<~RBS
        class Foo
          attr_reader name: untyped
          attr_reader count: Integer
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to eq("count" => "Integer")
      expect(info.types).not_to have_key("name")
    end

    it "resolve nesting profundo (3+ níveis)" do
      rbs = <<~RBS
        module A
          module B
            class C
              def x: () -> void
            end
          end
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "A::B::C")

      expect(info.types).to include("x")
    end

    it "resolve classe com :: absoluto" do
      rbs = <<~RBS
        class ::Admin::User
          def role: () -> String
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Admin::User")

      expect(info.types).to eq("role" => "String")
    end
  end

  describe ".has_class_methods_submodule?" do
    it "retorna true quando módulo contém sub-módulo ClassMethods" do
      rbs = <<~RBS
        module Devise
          module Models
            module Authenticatable
              module ClassMethods
                def find_by_email: (String) -> Authenticatable?
              end
            end
          end
        end
      RBS

      result = described_class.has_class_methods_submodule?(rbs, "Devise::Models::Authenticatable")

      expect(result).to eq(true)
    end

    it "retorna false quando módulo NÃO contém ClassMethods" do
      rbs = <<~RBS
        module Searchable
          def search: (String) -> Array[self]
        end
      RBS

      result = described_class.has_class_methods_submodule?(rbs, "Searchable")

      expect(result).to eq(false)
    end
  end

  describe ".sanitize_rbs_content" do
    it "remove linhas com protected (não suportado pelo RBS)" do
      content = <<~RBS
        class Foo
          def public_method: () -> void

          protected

          def protected_method: () -> untyped

          private

          def private_method: () -> void
        end
      RBS

      result = described_class.sanitize_rbs_content(content)

      expect(result).not_to match(/^\s*protected\s*$/)
      expect(result).to include("private")
      expect(result).to include("def public_method")
      expect(result).to include("def protected_method")
    end

    it "substitui anotações Steep (<% ... %>) por untyped" do
      content = <<~RBS
        class Foo
          @saas: <% Steep::AST::Types::Logic::Not %>
          def saas?: () -> untyped
        end
      RBS

      result = described_class.sanitize_rbs_content(content)

      expect(result).not_to include("<%")
      expect(result).to include("@saas: untyped")
    end
  end

  describe ".class_info_from_rbs com protected" do
    it "parseia RBS contendo protected sem erro" do
      rbs = <<~RBS
        class Foo
          def public_method: () -> String

          protected

          def protected_method: () -> Integer

          private

          def private_method: () -> void
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Foo")

      expect(info.types).to include("public_method" => "String")
      expect(info.types).to include("protected_method" => "Integer")
    end
  end

  describe ".class_info_from_rbs with generic declarations" do
    it "skips returns referencing type variables (no substitution at this layer)" do
      # Raw type variables leaking into generated RBS (`Model` etc.)
      # produce `Cannot find type` errors that poison the whole
      # environment (felixefelip/rbs_infer#19).
      rbs = <<~RBS
        module Methods[Model, PrimaryKey, ValidatedModel = Model]
          def find_by: (*untyped) -> (Model & ValidatedModel)?
          def count: () -> Integer
        end
      RBS

      info = described_class.class_info_from_rbs(rbs, "Methods")

      expect(info.types).not_to have_key("find_by")
      expect(info.types).to include("count" => "Integer")
    end
  end

  # felixefelip/rbs_infer#168. Everything rbs_infer emits reopens the class it
  # describes — one block for the class, one per nested class — and the index
  # kept only the last, so a lookup for the outer class saw the block holding
  # the inner one and answered "no methods". The recursive path
  # (`class_info_from_rbs`) has always unioned every match; these pin the two
  # to the same answer.
  describe ".class_info_from_index over a file that reopens the class" do
    let(:rbs) do
      <<~RBS
        class Example
          def ticket: () -> Ticket?
        end

        class Example
          class Registry
            def self.holder: () -> Holder?
          end
        end
      RBS
    end

    def info_via_index(class_name)
      index = described_class.build_declaration_index(described_class.parse_declarations(rbs))
      described_class.class_info_from_index(index, class_name)
    end

    it "unions the methods across every declaration of the class" do
      expect(info_via_index("Example").types).to include("ticket" => "Ticket?")
    end

    it "answers the same as the recursive path" do
      expect(info_via_index("Example").types)
        .to eq(described_class.class_info_from_rbs(rbs, "Example").types)
    end

    it "still finds a class declared only inside a later reopening" do
      expect(info_via_index("Example::Registry").class_method_types).to include("holder" => "Holder?")
    end

    it "takes the superclass from the declaration that states one" do
      reopened = <<~RBS
        class Example
          def a: () -> Integer
        end

        class Example < Base
          def b: () -> String
        end
      RBS

      index = described_class.build_declaration_index(described_class.parse_declarations(reopened))
      info = described_class.class_info_from_index(index, "Example")

      expect(info.superclass).to eq("Base")
      expect(info.types).to eq("a" => "Integer", "b" => "String")
    end
  end

  describe ".parenthesize_union" do
    it "wraps a bare top-level union (invalid in method-type position)" do
      expect(described_class.parenthesize_union("Integer | Float")).to eq("(Integer | Float)")
    end

    it "does not double-wrap an already parenthesized union" do
      expect(described_class.parenthesize_union("(Integer | Float)")).to eq("(Integer | Float)")
    end

    it "wraps when outer parens do not span the whole union" do
      expect(described_class.parenthesize_union("(A) | (B)")).to eq("((A) | (B))")
    end

    it "leaves optionals, plain types and generics untouched" do
      expect(described_class.parenthesize_union("(A | B)?")).to eq("(A | B)?")
      expect(described_class.parenthesize_union("User")).to eq("User")
      expect(described_class.parenthesize_union("Array[A | B]")).to eq("Array[A | B]")
    end

    it "returns unparseable strings as-is" do
      expect(described_class.parenthesize_union("| broken")).to eq("| broken")
    end

    it "wraps bare intersections (invalid in return position with ?)" do
      expect(described_class.parenthesize_compound("Caderneta & Caderneta::Validated"))
        .to eq("(Caderneta & Caderneta::Validated)")
    end
  end

  describe ".parenthesize_return_type" do
    it "wraps a bare union in return position (overload-separator ambiguity)" do
      # `def f: () -> bool | false` is parsed as two overloads → syntax error;
      # the parenthesized form is the only valid emission (rbs_infer#9).
      expect(described_class.parenthesize_return_type("accessible_to?: () -> bool | false"))
        .to eq("accessible_to?: () -> (bool | false)")
    end

    it "wraps regardless of params, including proc-typed params and blocks" do
      expect(described_class.parenthesize_return_type("f: (untyped user) -> bool | false"))
        .to eq("f: (untyped user) -> (bool | false)")
      expect(described_class.parenthesize_return_type("f: (^() -> void) -> String | Integer"))
        .to eq("f: (^() -> void) -> (String | Integer)")
      expect(described_class.parenthesize_return_type("f: () { () -> void } -> A | B"))
        .to eq("f: () { () -> void } -> (A | B)")
    end

    it "leaves already-valid return types untouched" do
      [
        "f: () -> bool",
        "f: () -> bool?",
        "f: () -> (bool | false)",
        "f: () -> (A | B)?",
        "f: () -> Array[String | Integer]",
        "f: () -> (^() -> void)",
        "x: untyped",
      ].each { |sig| expect(described_class.parenthesize_return_type(sig)).to eq(sig) }
    end
  end

  describe ".nilablize" do
    it "parenthesizes compounds before appending ? (bare A & B? binds to the last component)" do
      expect(described_class.nilablize("Caderneta & Caderneta::Validated"))
        .to eq("(Caderneta & Caderneta::Validated)?")
      expect(described_class.nilablize("Integer | Float")).to eq("(Integer | Float)?")
    end

    # `^() -> Symbol?` is a proc whose RETURN is optional, the proc itself still
    # mandatory — the opposite of what the caller asked for, and a
    # `MethodBodyTypeMismatch` on the method that stores such a block
    # (felixefelip/rbs_infer#237).
    it "parenthesizes a proc, whose `->` the ? would otherwise bind inside" do
      expect(described_class.nilablize("^(*untyped) -> Symbol"))
        .to eq("(^(*untyped) -> Symbol)?")
    end

    it "appends ? directly to simple types" do
      expect(described_class.nilablize("User")).to eq("User?")
      expect(described_class.nilablize("Array[User]")).to eq("Array[User]?")
      # A proc nested in a type argument is already delimited by the brackets.
      expect(described_class.nilablize("Array[^() -> void]")).to eq("Array[^() -> void]?")
    end

    # The parens `nilablize` needs are not the parens the member parser needs: a
    # bare proc in return position reads fine, so this one leaves it alone.
    it "leaves a proc alone in .parenthesize_compound" do
      expect(described_class.parenthesize_compound("^() -> void")).to eq("^() -> void")
    end

    it "is a no-op for already-optional types and nil" do
      expect(described_class.nilablize("(A & B)?")).to eq("(A & B)?")
      expect(described_class.nilablize("User?")).to eq("User?")
      expect(described_class.nilablize(nil)).to be_nil
    end
  end

  describe ".replace_block_param_types" do
    it "fills in the block's parameters, leaving the rest of the signature alone" do
      expect(described_class.replace_block_param_types(
        "authenticate: (untyped controller) { (untyped, untyped) -> untyped } -> untyped",
        ["String", "ActiveSupport::HashWithIndifferentAccess[untyped, untyped]?"]
      )).to eq("authenticate: (untyped controller) { (String, ActiveSupport::HashWithIndifferentAccess[untyped, untyped]?) -> untyped } -> untyped")
    end

    it "fills an optional block too" do
      expect(described_class.replace_block_param_types("m: () ?{ (untyped) -> untyped } -> untyped", ["String"]))
        .to eq("m: () ?{ (String) -> untyped } -> untyped")
    end

    # A parameter no site could type stays `untyped` rather than dragging the
    # whole block down with it.
    it "fills the parameters it knows and keeps the others" do
      expect(described_class.replace_block_param_types("m: () { (untyped, untyped) -> untyped } -> untyped", [nil, "Integer"]))
        .to eq("m: () { (untyped, Integer) -> untyped } -> untyped")
    end

    # A parameter list is unambiguous, unlike return position, so the wrapping
    # `TypeMerger` adds is redundant here — `(String | Integer, Integer)` reads
    # as two parameters either way.
    it "drops the redundant parens a merged union arrives with" do
      expect(described_class.replace_block_param_types("m: () { (untyped, untyped) -> untyped } -> untyped", ["(String | Integer)", "Integer"]))
        .to eq("m: () { (String | Integer, Integer) -> untyped } -> untyped")
    end

    it "keeps parens that are part of the type" do
      expect(described_class.replace_block_param_types("m: () { (untyped) -> untyped } -> untyped", ["(A & B)?"]))
        .to eq("m: () { ((A & B)?) -> untyped } -> untyped")
    end

    # Narrow on purpose: anything that isn't the shape the collector emits is
    # someone else's answer, and overwriting it would be a regression.
    it "leaves alone what it cannot account for" do
      [
        # arity unknown
        ["m: () { (*untyped) -> untyped } -> untyped", ["String"]],
        # length disagrees with the types on offer
        ["m: () { (untyped, untyped) -> untyped } -> untyped", ["String"]],
        # already refined, or hand-written
        ["m: () { (String) -> untyped } -> untyped", ["Integer"]],
        # no block at all
        ["m: (untyped a) -> untyped", ["String"]],
        # nothing to say
        ["m: () { (untyped) -> untyped } -> untyped", [nil]],
        ["m: () { (untyped) -> untyped } -> untyped", ["untyped"]],
        ["m: () { (untyped) -> untyped } -> untyped", []]
      ].each do |sig, types|
        expect(described_class.replace_block_param_types(sig, types)).to eq(sig)
      end
    end
  end

  describe ".replace_block_return_type" do
    it "fills in what the block returns, leaving its parameters alone" do
      expect(described_class.replace_block_return_type("m: () { (String) -> untyped } -> untyped", "User"))
        .to eq("m: () { (String) -> User } -> untyped")
    end

    # The mirror image of the parameter list, and measured rather than assumed:
    # `{ () -> A | B }` is a SYNTAX ERROR, while `{ (A | B) -> untyped }` is fine.
    it "parenthesizes a union, which is invalid bare in this position" do
      expect(described_class.replace_block_return_type("m: () { () -> untyped } -> untyped", "String | Integer"))
        .to eq("m: () { () -> (String | Integer) } -> untyped")
    end

    it "leaves alone what it cannot account for" do
      [
        # already refined, or hand-written
        ["m: () { (String) -> User } -> untyped", "Post"],
        # no block at all
        ["m: (untyped a) -> untyped", "User"],
        # nothing to say
        ["m: () { (String) -> untyped } -> untyped", nil],
        ["m: () { (String) -> untyped } -> untyped", "untyped"]
      ].each { |sig, type| expect(described_class.replace_block_return_type(sig, type)).to eq(sig) }
    end

    # The method's own return sits outside the braces and is somebody else's
    # answer — a `-> untyped` there must survive.
    it "touches only the return inside the braces" do
      expect(described_class.replace_block_return_type("m: () ?{ () -> untyped } -> untyped", "Post"))
        .to eq("m: () ?{ () -> Post } -> untyped")
    end

    # `bind_block_self` runs FIRST and puts the binding between the parameter
    # list and the arrow, so a clause that reaches here has usually got one.
    it "reaches past a `self` binding to the return behind it" do
      expect(described_class.replace_block_return_type("m: () ?{ (*untyped) [self: singleton(Bar)] -> untyped } -> untyped", "Symbol"))
        .to eq("m: () ?{ (*untyped) [self: singleton(Bar)] -> Symbol } -> untyped")
    end

    it "reads a bound clause whose self type is itself bracketed" do
      expect(described_class.replace_block_return_type("m: () { (String) [self: Array[Foo]] -> untyped } -> untyped", "Post"))
        .to eq("m: () { (String) [self: Array[Foo]] -> Post } -> untyped")
    end
  end

  describe ".bind_block_self" do
    it "binds `self` between the parameter list and the arrow" do
      expect(described_class.bind_block_self("m: () ?{ (*untyped) -> untyped } -> untyped", "singleton(Bar)"))
        .to eq("m: () ?{ (*untyped) [self: singleton(Bar)] -> untyped } -> untyped")
    end

    it "adds only the binding — not the `?`, not the parameter list" do
      expect(described_class.bind_block_self("m: () ?{ (String, Integer) -> Post } -> untyped", "Module"))
        .to eq("m: () ?{ (String, Integer) [self: Module] -> Post } -> untyped")
    end

    it "leaves alone what it cannot account for" do
      [
        # the clause already binds one — a hand-written annotation is the authority
        ["m: () ?{ (*untyped) [self: Module] -> untyped } -> untyped", "singleton(Bar)"],
        # no block at all
        ["m: (untyped a) -> untyped", "Module"],
        # nothing to say
        ["m: () ?{ (*untyped) -> untyped } -> untyped", nil],
        ["m: () ?{ (*untyped) -> untyped } -> untyped", "untyped"]
      ].each { |sig, self_type| expect(described_class.bind_block_self(sig, self_type)).to eq(sig) }
    end

    # A method that STORES its block also returns it, and that returned proc
    # carries the binding — which is not the block clause's, and must not be read
    # as one. Taking it for one left the clause unbound on exactly the passes
    # where the ivar holding the proc had already picked the binding up, so the
    # two alternated and the file never converged (felixefelip/rbs_infer#209).
    it "is not fooled by a `self` binding in the RETURN type" do
      sig = "bazingado: (?singleton(Bar)? base) ?{ (*untyped) -> Symbol } -> (^(*untyped) [self: singleton(Bar)] -> Symbol)?"

      expect(described_class.bind_block_self(sig, "singleton(Bar)"))
        .to eq("bazingado: (?singleton(Bar)? base) ?{ (*untyped) [self: singleton(Bar)] -> Symbol } -> (^(*untyped) [self: singleton(Bar)] -> Symbol)?")
    end

    # The pair, in the order `BlockSignatureResolver` applies them: binding, then
    # return. Both have to land, or the clause is a different type each pass.
    it "composes with the return replacement that follows it" do
      bound = described_class.bind_block_self("bazingado: (?singleton(Bar)? base) ?{ (*untyped) -> untyped } -> untyped", "singleton(Bar)")

      expect(described_class.replace_block_return_type(bound, "Symbol"))
        .to eq("bazingado: (?singleton(Bar)? base) ?{ (*untyped) [self: singleton(Bar)] -> Symbol } -> untyped")
    end
  end

  # The passes that CORRECT a declaration contradicting its body all start by
  # reading the declared return. A leftmost-matching `/->\s*(.+)$/` reads a
  # block clause's arrow instead, so every one of them silently skipped any
  # method taking a block (felixefelip/rbs_infer#252).
  describe ".return_type_of" do
    it "reads past a block clause's own arrow" do
      sig = "bazingado: (?singleton(Bar)? base) ?{ (*untyped) [self: singleton(Bar)] -> Symbol } -> " \
            "(^(*untyped) -> Symbol)?"

      expect(described_class.return_type_of(sig)).to eq("(^(*untyped) -> Symbol)?")
    end

    it "reads past a proc-typed parameter's arrow" do
      expect(described_class.return_type_of("m: (^(String) -> void callback) -> Integer")).to eq("Integer")
    end

    it "reads past the arrow inside the returned proc" do
      expect(described_class.return_type_of("m: () -> (^(*untyped) [self: singleton(Bar)] -> Symbol)?"))
        .to eq("(^(*untyped) [self: singleton(Bar)] -> Symbol)?")
    end

    it "reads a plain return" do
      expect(described_class.return_type_of("m: (String name) -> Integer")).to eq("Integer")
    end

    it "answers nil when there is no return arrow" do
      expect(described_class.return_type_of("attr_reader name: String")).to be_nil
    end
  end

  describe ".require_block" do
    it "adopts the callee's block: required, and shaped like theirs" do
      expect(described_class.require_block("m: () ?{ (*untyped) -> untyped } -> untyped", ["String", "Integer"]))
        .to eq("m: () { (String, Integer) -> untyped } -> untyped")
    end

    it "still requires one when the callee's shape is unreadable" do
      expect(described_class.require_block("m: () ?{ (*untyped) -> untyped } -> untyped", nil))
        .to eq("m: () { (*untyped) -> untyped } -> untyped")
    end

    # Only the "I just forward it" spelling is up for grabs; every other block
    # was settled by the body itself or by a hand-written annotation.
    it "touches nothing else" do
      [
        "m: () ?{ (untyped) -> untyped } -> untyped",
        "m: () { (*untyped) -> untyped } -> untyped",
        "m: () ?{ (String) -> untyped } -> untyped",
        "m: (untyped a) -> untyped"
      ].each { |sig| expect(described_class.require_block(sig, ["String"])).to eq(sig) }
    end
  end
end
