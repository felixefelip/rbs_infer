require "spec_helper"
require "rbs_infer/project/ruby_runtime_generator"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

RSpec.describe "bin/rbs_infer" do
  let(:bin_path) { File.expand_path("../../bin/rbs_infer", __dir__) }

  def run_rbs_infer(*args, dir:)
    stdout, stderr, status = Open3.capture3("ruby", bin_path, *args, chdir: dir)
    [stdout, stderr, status]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def write_file(relative_path, content)
    path = File.join(@tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def setup_project
    write_file("app/models/user.rb", <<~RUBY)
      class User
        attr_reader :name, :age

        def initialize(name:, age:)
          self.name = name
          self.age = age
        end

        def greeting
          "Hello"
        end

        private

        attr_writer :name, :age
      end
    RUBY

    write_file("app/models/post.rb", <<~RUBY)
      class Post
        attr_reader :title

        def initialize(title:)
          self.title = title
        end

        private

        attr_writer :title
      end
    RUBY

    write_file("app/services/create_user.rb", <<~RUBY)
      class CreateUser
        def call
          User.new(name: "Felix", age: 30)
        end
      end
    RUBY
  end

  # ─── Arquivo individual ──────────────────────────────────────────

  describe "com arquivo individual" do
    it "gera RBS para stdout" do
      setup_project
      stdout, _stderr, status = run_rbs_infer("app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout).to include("class User")
      expect(stdout).to include("attr_reader name")
      expect(stdout).to include("attr_reader age")
    end

    it "gera RBS para sig/generated/ com --output" do
      setup_project
      stdout, _stderr, status = run_rbs_infer("--output", "app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout.strip).to eq("sig/generated/app/models/user.rbs")

      rbs_path = File.join(@tmpdir, "sig/generated/app/models/user.rbs")
      expect(File.exist?(rbs_path)).to be true
      expect(File.read(rbs_path)).to include("class User")
    end
  end

  # ─── Diretório ───────────────────────────────────────────────────

  describe "com diretório" do
    it "processa todos os .rb do diretório recursivamente" do
      setup_project
      stdout, _stderr, status = run_rbs_infer("--output", "app/models", dir: @tmpdir)

      expect(status).to be_success
      lines = stdout.strip.split("\n")
      expect(lines).to contain_exactly(
        "sig/generated/app/models/user.rbs",
        "sig/generated/app/models/post.rbs"
      )

      expect(File.exist?(File.join(@tmpdir, "sig/generated/app/models/user.rbs"))).to be true
      expect(File.exist?(File.join(@tmpdir, "sig/generated/app/models/post.rbs"))).to be true
    end

    it "processa subdiretórios recursivamente" do
      setup_project
      write_file("app/models/admin/role.rb", <<~RUBY)
        class Admin::Role
          attr_reader :level #: Integer
        end
      RUBY

      stdout, _stderr, status = run_rbs_infer("--output", "app/models", dir: @tmpdir)

      expect(status).to be_success
      lines = stdout.strip.split("\n")
      expect(lines).to include("sig/generated/app/models/admin/role.rbs")
    end

    it "gera RBS para stdout sem --output" do
      setup_project
      stdout, _stderr, status = run_rbs_infer("app/models", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout).to include("class User")
      expect(stdout).to include("class Post")
    end
  end

  # ─── Múltiplos argumentos (arquivos e diretórios misturados) ─────

  describe "com múltiplos argumentos" do
    it "aceita mix de arquivo e diretório" do
      setup_project
      stdout, _stderr, status = run_rbs_infer("--output", "app/models/user.rb", "app/services", dir: @tmpdir)

      expect(status).to be_success
      lines = stdout.strip.split("\n")
      expect(lines).to include("sig/generated/app/models/user.rbs")
      expect(lines).to include("sig/generated/app/services/create_user.rbs")
    end
  end

  # ─── Erros ───────────────────────────────────────────────────────

  describe "tratamento de erros" do
    it "retorna exit 1 sem argumentos" do
      _stdout, _stderr, status = run_rbs_infer(dir: @tmpdir)

      expect(status.exitstatus).to eq(1)
    end

    it "retorna exit 1 para diretório vazio (sem .rb)" do
      empty_dir = File.join(@tmpdir, "empty")
      FileUtils.mkdir_p(empty_dir)

      _stdout, stderr, status = run_rbs_infer("empty", dir: @tmpdir)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("No .rb files found")
    end

    it "avisa quando classe não é encontrada no arquivo" do
      write_file("app/models/empty.rb", "# empty file\n")

      _stdout, stderr, status = run_rbs_infer("app/models/empty.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stderr).to include("class not found")
    end
  end

  # ─── --output-dir customizado ────────────────────────────────────

  describe "--output-dir" do
    it "escreve no diretório customizado" do
      setup_project
      stdout, _stderr, status = run_rbs_infer("--output-dir", "custom_sig", "app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout.strip).to eq("custom_sig/app/models/user.rbs")
      expect(File.exist?(File.join(@tmpdir, "custom_sig/app/models/user.rbs"))).to be true
    end
  end

  # ─── Multi-pass convergence ──────────────────────────────────────

  describe "multi-pass convergence" do
    it "does not re-run files when output is unchanged" do
      setup_project
      stdout, _stderr, status = run_rbs_infer("--output", "app/models/user.rb", dir: @tmpdir)
      expect(status).to be_success

      # Run again — since files already exist and content is the same, should print once
      stdout2, _stderr2, status2 = run_rbs_infer("--output", "app/models/user.rb", dir: @tmpdir)
      expect(status2).to be_success
      expect(stdout2.strip.split("\n").size).to eq(1)
    end
  end

  # ─── --max-passes ────────────────────────────────────────────────

  describe "--max-passes" do
    it "accepts --max-passes option" do
      setup_project
      stdout, stderr, status = run_rbs_infer("--max-passes", "3", "--output", "app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stderr).not_to include("Warning")
      expect(stdout.strip).to eq("sig/generated/app/models/user.rbs")
    end

    it "warns when convergence is not reached within max passes" do
      setup_project

      # With --max-passes 1, the loop body never executes (pass starts at 1,
      # condition is pass < max_passes which is 1 < 1 = false).
      # On a fresh run (no pre-existing RBS), files always change on pass 1,
      # so changed will be non-empty and the warning triggers.
      _stdout, stderr, status = run_rbs_infer(
        "--max-passes", "1", "--output", "app/models", dir: @tmpdir
      )

      expect(status).to be_success
      expect(stderr).to include("Warning: types did not converge after 1 stabilization passes")
      expect(stderr).to include("Try increasing --max-passes")
    end

    it "does not warn when types converge within max passes" do
      setup_project
      _stdout, stderr, status = run_rbs_infer(
        "--max-passes", "10", "--output", "app/models/user.rb", dir: @tmpdir
      )

      expect(status).to be_success
      expect(stderr).not_to include("Warning")
    end

    it "defaults to 10 passes without --max-passes" do
      setup_project
      # Just verify it runs successfully without the option
      _stdout, stderr, status = run_rbs_infer("--output", "app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stderr).not_to include("Warning")
    end
  end

  # ─── Callers fora do layout Rails (input entra no source_files) ──────
  #
  # `source_files` (o corpus de resolução de call-sites) precisa incluir os
  # arquivos de input, não só `app/`/`engines/`/`lib/`. Quando o caller de um
  # `.new` vive fora desse layout — p.ex. o pseudo-código AR-runtime sob
  # `sig/` — o call-site tem que continuar visível, senão a inferência de
  # param/getter degrada para `untyped`.
  describe "com callers fora de app/ (input no source_files)" do
    def setup_pseudo_project
      write_file("pseudo/widget.rb", <<~RUBY)
        class Widget
          attr_reader :name

          def initialize(name:)
            self.name = name
          end

          private

          attr_writer :name
        end
      RUBY

      # O ÚNICO caller de `Widget.new` vive sob `pseudo/`, fora de app/lib/engines.
      write_file("pseudo/factory.rb", <<~RUBY)
        class Factory
          def build
            Widget.new(name: "hi")
          end
        end
      RUBY
    end

    it "infere o param do initialize a partir de um caller fora de app/" do
      setup_pseudo_project
      stdout, _stderr, status = run_rbs_infer("pseudo", dir: @tmpdir)

      expect(status).to be_success
      # Sem o input no source_files, o call-site em pseudo/factory.rb some e o
      # param cai para `untyped`. Com a correção, resolve para String.
      expect(stdout).to include("def initialize: (name: String) -> void")
      expect(stdout).not_to include("name: untyped")
    end
  end

  # ─── O corpus vem do Steepfile ───────────────────────────────────
  #
  # `check` é onde o projeto diz que o Ruby dele mora, e é a MESMA lista que o
  # `steep check` lê — o corpus não pode divergir do que o checker enxerga.
  # Adivinhar o layout Rails errava nos dois sentidos: perdia um projeto que
  # guarda código em outro lugar, e perdia os sidecars sob `sig/`.
  describe "corpus vindo do Steepfile" do
    def write_steepfile(*checks)
      write_file("Steepfile", <<~RUBY)
        target :app do
        #{checks.map { |c| "  check #{c.inspect}" }.join("\n")}
          signature "sig"
        end
      RUBY
    end

    def write_widget(dir)
      write_file("#{dir}/widget.rb", <<~RUBY)
        class Widget
          attr_reader :name

          def initialize(name:)
            self.name = name
          end

          private

          attr_writer :name
        end
      RUBY
    end

    it "resolve um caller num diretório que o layout padrão nunca globaria" do
      write_steepfile("packages")
      write_widget("packages/billing")
      # O ÚNICO caller, e não é input do run — só o Steepfile o coloca no corpus.
      write_file("packages/billing/factory.rb", <<~RUBY)
        class Factory
          def build
            Widget.new(name: "hi")
          end
        end
      RUBY

      stdout, _stderr, status = run_rbs_infer("packages/billing/widget.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout).to include("def initialize: (name: String) -> void")
    end

    # A substituição tem um preço, e ele fica pinado aqui: o que o Steepfile não
    # declara não entra no corpus, nem que esteja em `app/`. Um projeto em
    # adoção gradual (`check "app/models"` e mais nada) resolve menos do que
    # resolvia com os globs fixos. É a consequência de o Steepfile ser a fonte
    # da verdade — para trazer o arquivo de volta, declare-o lá (ou passe-o como
    # input, que continua entrando no corpus).
    it "não lê o que o Steepfile não declara" do
      write_steepfile("packages")
      write_widget("packages/billing")
      write_file("app/services/factory.rb", <<~RUBY)
        class Factory
          def build
            Widget.new(name: "hi")
          end
        end
      RUBY

      stdout, _stderr, status = run_rbs_infer("packages/billing/widget.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout).to include("name: untyped")
    end

    # O input é do run, não do Steepfile: mandar analisar um arquivo é dizer que
    # ele conta, e o caller que vive junto dele tem que continuar visível
    # (felixefelip/rbs_infer#76).
    it "mantém os inputs no corpus mesmo fora do que o Steepfile declara" do
      write_steepfile("app")
      write_widget("pseudo")
      write_file("pseudo/factory.rb", <<~RUBY)
        class Factory
          def build
            Widget.new(name: "hi")
          end
        end
      RUBY

      stdout, _stderr, status = run_rbs_infer("pseudo", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout).to include("def initialize: (name: String) -> void")
    end

    # Sem Steepfile utilizável não há segunda resposta, mais silenciosa, para
    # onde cair: o run resolve contra o que lhe apontaram e DIZ isso. Um layout
    # adivinhado seria pior — degradaria tipo sem deixar rastro do motivo.
    it "avisa e resolve só os inputs quando o Steepfile não pode ser lido" do
      write_file("Steepfile", "target :app do\n  check\n")
      setup_project

      stdout, stderr, status = run_rbs_infer("app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stderr).to include("could not be read")
      expect(stderr).to include("resolving call sites only against the paths given")
      expect(stdout).to include("class User")
    end

    it "avisa quando o projeto não tem Steepfile nenhum" do
      setup_project

      _stdout, stderr, status = run_rbs_infer("app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stderr).to include("no usable Steepfile")
    end

    # O input continua sendo corpus, então apontar para o diretório inteiro
    # resolve o que vive dentro dele mesmo sem Steepfile.
    it "resolve dentro dos inputs mesmo sem Steepfile" do
      setup_project

      stdout, _stderr, status = run_rbs_infer("app", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout).to include("def initialize: (name: String, age: Integer) -> void")
    end
  end

  # ─── Pseudo-código sob sig/ entra no corpus (sem ser input) ──────
  #
  # Os sidecars de runtime não são só CALL-SITES, são DECLARAÇÕES que os passes
  # leem. `ActiveSupport::Concern` é transcrito sob
  # `sig/generated/steep_ar_runtime/` e é a única fonte do projeto que diz que
  # `class_methods do` guarda um bloco depois `module_eval`ado num
  # `ClassMethods`. Fora do corpus, o `StoredBlockReplayExpander` não desugara
  # nada e o `module ClassMethods` some do RBS — com `--output`, apagado por
  # cima do bom. O run completo escapava só porque a invocação usual passa
  # `sig/` como INPUT (`rbs_infer app/ lib/ sig/`).
  describe "com declarações sob sig/ (pseudo-código no corpus)" do
    def setup_concern_project
      # `check "sig/**/*.rb"` é o que o app que reportou o bug já dizia: o
      # pseudo-código é Ruby que o projeto manda o Steep checar.
      write_file("Steepfile", <<~RUBY)
        target :app do
          check "app"
          check "sig/**/*.rb"
          signature "sig"
        end
      RUBY

      # A transcrição da linguagem, que todo projeto tem em disco: sem ela o
      # `extend` não chega na emenda e o bloco não sai do lugar (#311).
      RbsInfer::Project::RubyRuntimeGenerator.new(app_dir: @tmpdir).generate

      # A transcrição que o gerador de AR-runtime emite, reduzida ao que este
      # caso lê: `class_methods` guardando o bloco num `ClassMethods`.
      write_file("sig/generated/steep_ar_runtime/active_support/concern.rb", <<~RUBY)
        module ActiveSupport
          module Concern
            def self.extended(base)
              base.instance_variable_set(:@_dependencies, Array.new)
            end

            def class_methods(&class_methods_module_definition)
              mod = const_defined?(:ClassMethods) ? const_get(:ClassMethods) : const_set(:ClassMethods, Module.new)

              mod.module_eval(&class_methods_module_definition)
            end
          end
        end
      RUBY

      write_file("app/models/greeter.rb", <<~RUBY)
        module Greeter
          extend ActiveSupport::Concern

          class_methods do
            def greeting
              "hello"
            end
          end
        end
      RUBY
    end

    it "desugara `class_methods do` num run de arquivo único" do
      setup_concern_project
      stdout, _stderr, status = run_rbs_infer("app/models/greeter.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout).to include("module ClassMethods")
      expect(stdout).to include("def greeting: () -> String")
    end

    # O `**` do `Dir.glob` não desce em diretório oculto, e é disso que depende
    # a view expandida sob `sig/generated/.expanded/` — cópia literal das fontes
    # do app — não entrar no corpus: com ela dentro, cada constante ganharia um
    # segundo arquivo declarando-a.
    it "não puxa a view expandida de volta para o corpus" do
      write_file("Steepfile", <<~RUBY)
        target :app do
          check "app"
          check "sig/**/*.rb"
          signature "sig"
        end
      RUBY
      setup_project
      run_rbs_infer("--output", "app/models/user.rb", dir: @tmpdir)
      expect(File.exist?(File.join(@tmpdir, "sig/generated/.expanded/app/models/user.rb"))).to be false

      # Escrita à mão: o expander pode não ter emitido nada acima, e o que se
      # pina aqui é o glob, não quem escreve o arquivo.
      write_file("sig/generated/.expanded/app/models/user.rb", File.read(File.join(@tmpdir, "app/models/user.rb")))

      stdout, _stderr, status = run_rbs_infer("app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(stdout.scan(/class User\b/).size).to eq(1)
    end
  end

  # ─── O sidecar de postconditions não é do rbs_infer sozinho ───────
  #
  # Steep escreve os postconditions que ele mesmo infere em
  # `sig/generated/.steep_postconditions.yml`
  # (`Steep::Postconditions::Runner::DEFAULT_OUTPUT_PATH`) — o MESMO caminho que
  # `File.join(output_dir, ".steep_postconditions.yml")` dá no `--output-dir`
  # padrão. Enquanto os dois dividiram o caminho, quem rodasse por último
  # vencia, nos dois sentidos: um projeto sem `self.class.class_eval` apagava o
  # arquivo do Steep a cada run (o `rm_f`), e um projeto com um sobrescrevia as
  # entradas dele. O `sig/**/.steep_postconditions.yml` do Steep faz merge de
  # vários arquivos — o que faltava era o rbs_infer escrever no diretório dele.
  describe "sidecar de postconditions" do
    def setup_class_eval_project
      write_file("app/models/foo.rb", <<~RUBY)
        class Foo
          def build_age
            self.class.class_eval do
              def age
                42
              end
            end
          end
        end
      RUBY
    end

    # O arquivo do Steep é um dado de entrada do rbs_infer: sem ele o
    # `current_user` de um controller volta a ser nilable, o `@x = current_user.y`
    # vira erro de tipo, e o ivar deixa de ser declarado.
    def write_steep_sidecar(content = "--- {}\n")
      write_file("sig/generated/.steep_postconditions.yml", content)
    end

    it "não apaga o sidecar do Steep quando não tem nada a emitir" do
      setup_project
      write_steep_sidecar

      _stdout, _stderr, status = run_rbs_infer("--output", "app/models/user.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(File.exist?(File.join(@tmpdir, "sig/generated/.steep_postconditions.yml"))).to be true
    end

    it "não sobrescreve o sidecar do Steep quando tem o que emitir" do
      setup_class_eval_project
      write_steep_sidecar

      _stdout, _stderr, status = run_rbs_infer("--output", "app/models/foo.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(File.read(File.join(@tmpdir, "sig/generated/.steep_postconditions.yml"))).to eq("--- {}\n")
    end

    # Num diretório próprio, e não um dot-directory: o glob do Steep é um
    # `Dir.glob` comum, cujo `**` não desce em diretório oculto — um
    # `.rbs_infer_postconditions/` seria escrito e nunca lido.
    it "emite no próprio diretório, onde o glob do Steep alcança" do
      setup_class_eval_project

      stdout, _stderr, status = run_rbs_infer("--output", "app/models/foo.rb", dir: @tmpdir)

      sidecar = "sig/generated/rbs_infer_postconditions/.steep_postconditions.yml"
      expect(status).to be_success
      expect(stdout).to include(sidecar)
      expect(YAML.safe_load(File.read(File.join(@tmpdir, sidecar)))["postconditions"]).to include(
        a_hash_including("class" => "Foo", "method" => "build_age")
      )
      expect(Dir.glob(File.join(@tmpdir, "sig/**/.steep_postconditions.yml")))
        .to include(File.join(@tmpdir, sidecar))
    end

    it "remove o próprio sidecar quando deixa de ter o que emitir" do
      setup_class_eval_project
      run_rbs_infer("--output", "app/models/foo.rb", dir: @tmpdir)

      write_file("app/models/foo.rb", "class Foo\n  def build_age\n    nil\n  end\nend\n")
      _stdout, _stderr, status = run_rbs_infer("--output", "app/models/foo.rb", dir: @tmpdir)

      expect(status).to be_success
      expect(File.exist?(File.join(@tmpdir,
                                   "sig/generated/rbs_infer_postconditions/.steep_postconditions.yml"))).to be false
    end
  end
end
