require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"

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
end
