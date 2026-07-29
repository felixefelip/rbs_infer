require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../../support/temp_file_helpers"

RSpec.describe RbsInfer::Inference::NewCallCollector do
  include TempFileHelpers

  # Test-only default for the required `constant_arg_resolver` (#46); these
  # specs don't exercise constant args, so a null-tier resolver suffices.
  def null_constant_resolver
    RbsInfer::Inference::ConstantArgTypeResolver.new(steep_bridge: nil, caller_constant_types: {})
  end

  def collect_usages(source, target_class:, method_return_types: {}, local_var_types: {})
    result = Prism.parse(source)
    visitor = described_class.new(
      target_class: target_class,
      method_return_types: method_return_types,
      local_var_types: local_var_types,
      constant_arg_resolver: null_constant_resolver,
      defined_class_names: described_class.collect_defined_class_names(result.value)
    )
    result.value.accept(visitor)
    visitor.usages
  end

  it "coleta kwargs de chamadas .new com literais" do
    source = <<~RUBY
      Foo.new(nome: "teste", idade: 42)
    RUBY

    usages = collect_usages(source, target_class: "Foo")
    expect(usages.size).to eq(1)
    expect(usages.first["nome"]).to eq("String")
    expect(usages.first["idade"]).to eq("Integer")
  end

  it "resolve variáveis locais atribuídas via method call" do
    source = <<~RUBY
      def test
        dto = build_dto
        Foo.new(data: dto)
      end
    RUBY

    usages = collect_usages(source,
      target_class: "Foo",
      method_return_types: { "build_dto" => "MyDto" })
    expect(usages.first["data"]).to eq("MyDto")
  end

  it "resolve variáveis locais atribuídas via Klass.new" do
    source = <<~RUBY
      def test
        client = Client::Entity.new(name: "x")
        Enroll.new(client: client)
      end
    RUBY

    usages = collect_usages(source, target_class: "Enroll")
    expect(usages.first["client"]).to eq("Client::Entity")
  end

  it "resolve class method via resolver como tipo da variável local" do
    files = {
      "sig/record.rbs" => <<~RBS,
        class Record
          def self.find_by!: (String email) -> Record
        end
      RBS
      "caller.rb" => <<~RUBY
        def test
          record = Record.find_by!(email: "x")
          Target.new(record: record)
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      Dir.chdir(dir) do
        resolver = RbsInfer::Signatures::MethodTypeResolver.new(paths, constant_resolver: fake_constant_resolver)
        source = File.read(paths.last)
        result = Prism.parse(source)
        visitor = described_class.new(
          target_class: "Target",
          method_return_types: {},
          local_var_types: {},
          method_type_resolver: resolver,
          constant_arg_resolver: null_constant_resolver,
          defined_class_names: described_class.collect_defined_class_names(result.value)
        )
        result.value.accept(visitor)
        expect(visitor.usages.first["record"]).to eq("Record")
      end
    end
  end

  it "match relativo: Email == Academico::Aluno::Email" do
    source = <<~RUBY
      Email.new(endereco: "test@email.com")
    RUBY

    usages = collect_usages(source, target_class: "Academico::Aluno::Email")
    expect(usages.size).to eq(1)
    expect(usages.first["endereco"]).to eq("String")
  end

  it "não faz match parcial incorreto" do
    source = <<~RUBY
      SuperEmail.new(endereco: "test")
    RUBY

    usages = collect_usages(source, target_class: "Academico::Aluno::Email")
    expect(usages).to be_empty
  end

  it "resolve implicit hash values" do
    source = <<~RUBY
      def process
        nome = build_nome
        Foo.new(nome:)
      end
    RUBY

    usages = collect_usages(source,
      target_class: "Foo",
      method_return_types: { "build_nome" => "String" })
    expect(usages.first["nome"]).to eq("String")
  end

  describe "self as a .new argument (regression)" do
    # `Cadastrar.new(self)` inside `Caderneta#criar_caderneta_de_vacinacao`
    # should infer the positional `initialize(caderneta)` param as
    # `Caderneta` — `self` resolves to the lexically-enclosing class.
    # Previously `self` fell through to `untyped`.
    def collect_with_self(source, target_class:, caller_class_name:, init_positional_params:, self_types_by_method: {})
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: {},
        caller_class_name: caller_class_name,
        init_positional_params: init_positional_params,
        self_types_by_method: self_types_by_method,
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value)
      )
      result.value.accept(visitor)
      visitor.usages
    end

    it "infers self in an instance method as the enclosing class instance" do
      source = <<~RUBY
        class Caderneta
          def criar_caderneta_de_vacinacao
            Cadastrar.new(self).call
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Caderneta::Cadastrar",
        caller_class_name: "Caderneta",
        init_positional_params: ["caderneta"]
      )
      expect(usages.first["caderneta"]).to eq("Caderneta")
    end

    it "infers self in a singleton method as singleton(EnclosingClass)" do
      source = <<~RUBY
        class Caderneta
          def self.build
            Cadastrar.new(self)
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Caderneta::Cadastrar",
        caller_class_name: "Caderneta",
        init_positional_params: ["caderneta"]
      )
      expect(usages.first["caderneta"]).to eq("singleton(Caderneta)")
    end

    it "resolves self to the innermost lexically-enclosing class when nested" do
      source = <<~RUBY
        class Outer
          class Inner
            def make
              Target.new(self)
            end
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Outer::Inner::Target",
        caller_class_name: "Outer",
        init_positional_params: ["owner"]
      )
      expect(usages.first["owner"]).to eq("Outer::Inner")
    end

    # After-validation callback narrowing: inside an `after_create` handler
    # the record is validated, so `self` (and thus `Cadastrar.new(self)`)
    # should be `Caderneta & Caderneta::Validated`. The refined self type
    # comes from the callback sidecar (SteepBridge#callback_self_types) since
    # Steep keeps `self` abstract in its typing output.
    it "prefers the callback-refined self type over the lexical class" do
      source = <<~RUBY
        class Caderneta
          def criar_caderneta_de_vacinacao
            Cadastrar.new(self).call
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Caderneta::Cadastrar",
        caller_class_name: "Caderneta",
        init_positional_params: ["caderneta"],
        self_types_by_method: { "criar_caderneta_de_vacinacao" => "Caderneta & Caderneta::Validated" }
      )
      expect(usages.first["caderneta"]).to eq("Caderneta & Caderneta::Validated")
    end

    it "uses the lexical class for methods not covered by a callback entry" do
      source = <<~RUBY
        class Caderneta
          def some_other_method
            Cadastrar.new(self)
          end
        end
      RUBY

      usages = collect_with_self(
        source,
        target_class: "Caderneta::Cadastrar",
        caller_class_name: "Caderneta",
        init_positional_params: ["caderneta"],
        self_types_by_method: { "criar_caderneta_de_vacinacao" => "Caderneta & Caderneta::Validated" }
      )
      expect(usages.first["caderneta"]).to eq("Caderneta")
    end

    it "falls back to untyped when self has no resolvable class context" do
      # No enclosing class node and no caller_class_name.
      source = "Target.new(self)"
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: "Target",
        method_return_types: {},
        local_var_types: {},
        init_positional_params: ["owner"],
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value)
      )
      result.value.accept(visitor)
      expect(visitor.usages.first["owner"]).to eq("untyped")
    end
  end

  describe "ivar/local name collision (regression)" do
    # The ERB caller resolver passes ivar types keyed by `@name`
    # (with prefix) and locals keyed by `name`. The collector's
    # `InstanceVariableReadNode` lookup must use the prefixed key so
    # an ivar named `@company` doesn't shadow a local named `company`
    # of unrelated type, and vice-versa.

    it "resolves @ivar via the @-prefixed key" do
      source = <<~RUBY
        Foo.new(value: @company)
      RUBY

      usages = collect_usages(
        source,
        target_class: "Foo",
        local_var_types: { "@company" => "WideCompany", "company" => "NarrowCompany" }
      )
      expect(usages.first["value"]).to eq("WideCompany")
    end

    it "resolves local var via the unprefixed key without seeing the ivar entry" do
      source = <<~RUBY
        def test
          # `company` is a method-local, NOT the ivar @company.
          company = pick_one
          Foo.new(value: company)
        end
      RUBY

      usages = collect_usages(
        source,
        target_class: "Foo",
        method_return_types: { "pick_one" => "NarrowCompany" },
        local_var_types: { "@company" => "WideCompany" }
      )
      expect(usages.first["value"]).to eq("NarrowCompany")
    end

    it "falls back to the unprefixed key when only that one is set (backward compat with in-class collect_class_ivar_types)" do
      # `collect_class_ivar_types` writes ivars under their bare name
      # (no `@`). The lookup should still find them.
      source = <<~RUBY
        Foo.new(value: @company)
      RUBY

      usages = collect_usages(
        source,
        target_class: "Foo",
        local_var_types: { "company" => "LegacyCompany" }
      )
      expect(usages.first["value"]).to eq("LegacyCompany")
    end
  end

  describe "target-method calls through marker-decorated / self-refined receivers" do
    # Peça B: the receiver type carries markers, i.e. it's an intersection
    # like `Caderneta & Caderneta::Validated`. `match_class?` must recognize
    # the target class as one of the intersection's components, otherwise the
    # call is silently dropped and the argument types are never collected.
    it "matches a target call whose receiver resolves to an intersection type" do
      source = "caderneta.qtde_por_vacina(v)"
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: "Caderneta",
        method_return_types: { "caderneta" => "Caderneta & Caderneta::Validated", "v" => "Vacina" },
        local_var_types: {},
        target_methods: { "qtde_por_vacina" => ["vacina"] },
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value)
      )
      result.value.accept(visitor)

      expect(visitor.method_call_usages["qtde_por_vacina"]).to eq([{ "vacina" => "Vacina" }])
    end

    # felixefelip/rbs_infer#131. Decomposing only the intersection left every
    # NILABLE receiver unmatched, and a CurrentAttributes reader is honestly nilable
    # (per-request reset) — so `Current.<attr>.method(arg)` never contributed an
    # argument type anywhere in the app, silently.
    {
      "nilable" => "(Caderneta & Caderneta::Validated)?",
      "union of the ivar's write shapes" => "((Caderneta & Caderneta::Validated) | Caderneta)?",
      "plain nilable, no marker" => "Caderneta?"
    }.each do |shape, receiver_type|
      it "matches a target call whose receiver resolves to a #{shape} type" do
        source = "caderneta.qtde_por_vacina(v)"
        result = Prism.parse(source)
        visitor = described_class.new(
          target_class: "Caderneta",
          method_return_types: { "caderneta" => receiver_type, "v" => "Vacina" },
          local_var_types: {},
          target_methods: { "qtde_por_vacina" => ["vacina"] },
          constant_arg_resolver: null_constant_resolver,
          defined_class_names: described_class.collect_defined_class_names(result.value)
        )
        result.value.accept(visitor)

        expect(visitor.method_call_usages["qtde_por_vacina"]).to eq([{ "vacina" => "Vacina" }])
      end
    end

    it "still refuses a receiver that is not the target" do
      source = "vacina.qtde_por_vacina(v)"
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: "Caderneta",
        method_return_types: { "vacina" => "(Vacina & Vacina::Validated)?", "v" => "Vacina" },
        local_var_types: {},
        target_methods: { "qtde_por_vacina" => ["vacina"] },
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value)
      )
      result.value.accept(visitor)

      expect(visitor.method_call_usages).to be_empty
    end

    # `singleton(Caderneta)` is the CLASS, not an instance of it. A class-method
    # call must not be read as a call on an instance.
    it "does not match a singleton receiver against the instance target" do
      source = "klass.qtde_por_vacina(v)"
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: "Caderneta",
        method_return_types: { "klass" => "singleton(Caderneta)", "v" => "Vacina" },
        local_var_types: {},
        target_methods: { "qtde_por_vacina" => ["vacina"] },
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value)
      )
      result.value.accept(visitor)

      expect(visitor.method_call_usages).to be_empty
    end

    # Peça A: inside a method whose `self` is callback-refined, a
    # `self.<association>` used as the receiver OR as an argument resolves
    # against that refined self (the marker-decorated reader), not the base
    # nilable reader — so both the receiver match and the argument type pick
    # up the validated type.
    it "resolves self.<association> receiver and argument against the refined self" do
      files = {
        "sig/holder.rbs" => <<~RBS,
          class Holder
            def thing: () -> Thing?
            def other: () -> Other?
          end

          class Holder::Validated
            def thing: () -> (Thing & Thing::Validated)
            def other: () -> (Other & Other::Validated)
          end

          class Thing
          end
          class Thing::Validated
          end
          class Other
          end
          class Other::Validated
          end
        RBS
        "caller.rb" => <<~RUBY
          class Holder
            def m
              thing.target_method(other)
            end
          end
        RUBY
      }

      with_temp_files(files) do |dir, paths|
        Dir.chdir(dir) do
          resolver = RbsInfer::Signatures::MethodTypeResolver.new(paths, constant_resolver: fake_constant_resolver)
          source = File.read(File.join(dir, "caller.rb"))
          result = Prism.parse(source)
          visitor = described_class.new(
            target_class: "Thing",
            method_return_types: {},
            local_var_types: {},
            method_type_resolver: resolver,
            caller_class_name: "Holder",
            target_methods: { "target_method" => ["arg"] },
            self_types_by_method: { "m" => "Holder & Holder::Validated" },
            constant_arg_resolver: null_constant_resolver,
            defined_class_names: described_class.collect_defined_class_names(result.value)
          )
          result.value.accept(visitor)

          expect(visitor.method_call_usages["target_method"]).to eq(
            [{ "arg" => "Other & Other::Validated" }]
          )
        end
      end
    end
  end

  describe "external attr-setter call-sites (rbs_infer#71)" do
    def collect_method_usages(source, target_class:, target_methods:, local_var_types: {})
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: local_var_types,
        constant_arg_resolver: null_constant_resolver,
        target_methods: target_methods,
        defined_class_names: described_class.collect_defined_class_names(result.value)
      )
      result.value.accept(visitor)
      visitor.method_call_usages
    end

    it "captures `receiver.attr = value` as a usage of the synthetic `attr=` writer" do
      # `board=` is exposed as a target method (the attr writer). A
      # `column.board = value` with `column : Column` is just a call to it.
      source = <<~RUBY
        column = build_column
        assigned = build_board
        column.board = assigned
      RUBY
      usages = collect_method_usages(
        source,
        target_class: "Column",
        target_methods: { "board=" => ["board"] },
        local_var_types: { "column" => "Column", "assigned" => "Board" }
      )
      expect(usages["board="]).to eq([{ "board" => "Board" }])
    end

    it "ignores the setter when the receiver is not the target class" do
      source = <<~RUBY
        other = build_other
        assigned = build_board
        other.board = assigned
      RUBY
      usages = collect_method_usages(
        source,
        target_class: "Column",
        target_methods: { "board=" => ["board"] },
        local_var_types: { "other" => "Widget", "assigned" => "Board" }
      )
      expect(usages).to be_empty
    end
  end

  describe "same-simple-name classes are not conflated (cross-class leak)" do
    def collect_method_usages(source, target_class:, target_methods:, local_var_types: {})
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: local_var_types,
        constant_arg_resolver: null_constant_resolver,
        target_methods: target_methods,
        defined_class_names: described_class.collect_defined_class_names(result.value)
      )
      result.value.accept(visitor)
      visitor.method_call_usages
    end

    # Two classes share the simple name `Foo` in different namespaces. A bare
    # `Foo.user = nil` written inside `Example3` is `Example3::Foo` (Ruby
    # resolves it against the lexical nesting), so it must NOT leak into the
    # unrelated `Example2::Foo` — the file defines `Example3::Foo`, which is the
    # sound signal that the spelling is that class, not the same-named target.
    SAME_NAME_SOURCE = <<~RUBY
      class Example3
        class Foo
          def user=(value); end
        end

        def self.run
          Foo.user = nil
        end
      end
    RUBY

    it "does not capture the call for a same-named sibling target" do
      usages = collect_method_usages(
        SAME_NAME_SOURCE,
        target_class: "Example2::Foo",
        target_methods: { "user=" => ["value"] }
      )
      expect(usages["user="]).to be_empty
    end

    it "still captures the call for the target the spelling actually resolves to" do
      usages = collect_method_usages(
        SAME_NAME_SOURCE,
        target_class: "Example3::Foo",
        target_methods: { "user=" => ["value"] }
      )
      expect(usages["user="]).to eq([{ "value" => "nil" }])
    end
  end

  # felixefelip/rbs_infer#109. A controller's declared `@post` is nilable (the
  # ivar is assigned in `set_post`, not in `initialize`), but past the `set_post`
  # call it is narrowed. The narrowing is a FLOW fact the analyzer cannot derive,
  # so it is read from the postconditions sidecar and applied in SOURCE ORDER.
  describe "ivars established by a self-call (postconditions sidecar)" do
    def collect_with_established(source, target_class:, established:)
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: {},
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value),
        established_ivars_by_method: established
      )
      result.value.accept(visitor)
      visitor.usages
    end

    let(:established) { { "set_post" => { "@post" => "(Post & Post::Validated)" } } }

    it "narrows an ivar argument after the establishing call" do
      source = <<~RUBY
        class PostsController
          def run
            set_post
            View.new(post: @post)
          end
        end
      RUBY

      usages = collect_with_established(source, target_class: "View", established: established)

      expect(usages.first["post"]).to eq("(Post & Post::Validated)")
    end

    it "does not narrow a call site written BEFORE the establishing call" do
      # The ivar is not populated yet at that point, so claiming the narrowed
      # type there would be a fact the source does not support.
      source = <<~RUBY
        class PostsController
          def run
            View.new(post: @post)
            set_post
          end
        end
      RUBY

      usages = collect_with_established(source, target_class: "View", established: established)

      expect(usages.first["post"]).to eq("untyped")
    end

    it "does not leak the narrowing into a sibling method" do
      source = <<~RUBY
        class PostsController
          def one
            set_post
          end

          def two
            View.new(post: @post)
          end
        end
      RUBY

      usages = collect_with_established(source, target_class: "View", established: established)

      expect(usages.first["post"]).to eq("untyped")
    end

    it "ignores an establishing call made on another object" do
      # `other.set_post` writes THAT object's ivars, not ours.
      source = <<~RUBY
        class PostsController
          def run
            other.set_post
            View.new(post: @post)
          end
        end
      RUBY

      usages = collect_with_established(source, target_class: "View", established: established)

      expect(usages.first["post"]).to eq("untyped")
    end

    it "leaves the argument alone when no method establishes it" do
      source = <<~RUBY
        class PostsController
          def run
            set_post
            View.new(other: @other)
          end
        end
      RUBY

      usages = collect_with_established(source, target_class: "View", established: established)

      expect(usages.first["other"]).to eq("untyped")
    end
  end


  # Argument-sensitive partitions (felixefelip/steep#89, #91, #95). A `case <param>` branch
  # is reachable only for callers who passed that literal, so the facts those callers
  # established hold inside it — and only inside it. This is what keeps a shared dispatcher
  # (a controller's `render` override, reached from every action) from collapsing to the
  # meet over all its callers.
  describe "ivars from an argument partition" do
    def collect_with_partitions(source, target_class:, partitions:)
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: {},
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value),
        argument_partitions_by_method: partitions
      )
      result.value.accept(visitor)
      visitor.usages
    end

    let(:partitions) do
      {
        "render" => [
          { param: "target", pattern: ":edit", ivars: { "@post" => "Post & Post::Validated" } },
          { param: "target", pattern: ":new", ivars: { "@post" => "Post" } }
        ]
      }
    end

    def render_source(body)
      <<~RUBY
        class PostsController
          def render(target = nil, *rest)
            #{body}
          end
        end
      RUBY
    end

    it "applies the matching literal's partition inside its branch" do
      usages = collect_with_partitions(
        render_source("case target\nwhen :edit then View.new(post: @post)\nend"),
        target_class: "View", partitions: partitions
      )

      expect(usages.first["post"]).to eq("Post & Post::Validated")
    end

    it "gives each branch its own partition" do
      usages = collect_with_partitions(
        render_source("case target\nwhen :edit then View.new(post: @post)\nwhen :new then View.new(post: @post)\nend"),
        target_class: "View", partitions: partitions
      )

      expect(usages.map { |u| u["post"] }).to contain_exactly("Post & Post::Validated", "Post")
    end

    it "does not leak a partition past the case" do
      usages = collect_with_partitions(
        render_source("case target\nwhen :edit then nil\nend\nView.new(post: @post)"),
        target_class: "View", partitions: partitions
      )

      expect(usages.first["post"]).to eq("untyped")
    end

    it "ignores a branch whose literal has no partition" do
      usages = collect_with_partitions(
        render_source("case target\nwhen :other then View.new(post: @post)\nend"),
        target_class: "View", partitions: partitions
      )

      expect(usages.first["post"]).to eq("untyped")
    end

    it "ignores a case on something that is not the partitioned parameter" do
      # The correlation is between the CALLER's argument and the branch. A `case` on
      # anything else says nothing about what the caller passed.
      usages = collect_with_partitions(
        render_source("case rest\nwhen :edit then View.new(post: @post)\nend"),
        target_class: "View", partitions: partitions
      )

      expect(usages.first["post"]).to eq("untyped")
    end

    it "leaves the else branch alone" do
      usages = collect_with_partitions(
        render_source("case target\nwhen :edit then nil\nelse View.new(post: @post)\nend"),
        target_class: "View", partitions: partitions
      )

      expect(usages.first["post"]).to eq("untyped")
    end
  end


  # Ruby 3: when the callee accepts NO keyword parameters, keywords at the call site are
  # passed as a positional Hash. Skipping them made the argument vanish, so the parameter
  # was typed from the OTHER call sites alone — narrow enough to reject real calls, which
  # is worse than imprecise.
  describe "a keyword hash that collapses to a positional argument" do
    def collect_calls(source, target_class:, target_methods:)
      result = Prism.parse(source)
      visitor = described_class.new(
        target_class: target_class,
        method_return_types: {},
        local_var_types: {},
        constant_arg_resolver: null_constant_resolver,
        defined_class_names: described_class.collect_defined_class_names(result.value),
        target_methods: target_methods
      )
      result.value.accept(visitor)
      visitor.method_call_usages
    end

    it "binds it to the free positional parameter when no key names one" do
      usages = collect_calls(
        'View.new.render(partial: "posts/form")',
        target_class: "View", target_methods: { "render" => ["target"] }
      )

      expect(usages["render"].first["target"]).to eq("{ partial: String }")
    end

    # A record keeps each key bound to its own value type. `Hash[Symbol, String | Post]`
    # says only "some symbol maps to one of these", which loses which is which.
    it "types it as a record, not a flattened key/value Hash" do
      usages = collect_calls(
        'View.new.render(partial: "posts/form", count: 2)',
        target_class: "View", target_methods: { "render" => ["target"] }
      )

      expect(usages["render"].first["target"]).to eq("{ partial: String, count: Integer }")
    end

    it "builds a record for a nested hash too, so `locals:` keeps its own keys" do
      usages = collect_calls(
        'View.new.render(partial: "posts/form", locals: { count: 2 })',
        target_class: "View", target_methods: { "render" => ["target"] }
      )

      expect(usages["render"].first["target"])
        .to eq("{ partial: String, locals: { count: Integer } }")
    end

    # A record type can only describe all-symbol keys; anything else keeps `Hash[K, V]`.
    it "falls back to a Hash when a nested key is not a symbol" do
      usages = collect_calls(
        'View.new.render(partial: "posts/form", locals: { "count" => 2 })',
        target_class: "View", target_methods: { "render" => ["target"] }
      )

      expect(usages["render"].first["target"])
        .to eq("{ partial: String, locals: Hash[String, untyped] }")
    end

    it "keeps a real keyword argument as a keyword" do
      # `partial` IS a parameter here, so the call site is passing keywords for real.
      usages = collect_calls(
        'View.new.render(partial: "posts/form")',
        target_class: "View", target_methods: { "render" => ["partial"] }
      )

      expect(usages["render"].first["partial"]).to eq("String")
      expect(usages["render"].first).not_to have_key("target")
    end

    it "does not consume a positional slot already filled" do
      usages = collect_calls(
        'View.new.render("posts/summary", post: 1)',
        target_class: "View", target_methods: { "render" => ["target"] }
      )

      expect(usages["render"].first["target"]).to eq("String")
    end
  end

end
