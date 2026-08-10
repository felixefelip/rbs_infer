require "spec_helper"
require "rbs_infer"
require "tmpdir"

RSpec.describe RbsInfer::Project::SourceIndex do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write_file(name, content)
    path = File.join(@dir, name)
    File.write(path, content)
    path
  end

  it "indexa classes CamelCase e retorna arquivos referenciando" do
    f1 = write_file("a.rb", "Post.new(title: 'x')")
    f2 = write_file("b.rb", "User.find(1)")
    f3 = write_file("c.rb", "tag = Tag.new; Post.create")

    index = described_class.new([f1, f2, f3])

    expect(index.files_referencing("Post")).to contain_exactly(f1, f3)
    expect(index.files_referencing("User")).to contain_exactly(f2)
    expect(index.files_referencing("Tag")).to contain_exactly(f3)
  end

  it "usa o último segmento do namespace para lookup" do
    f1 = write_file("a.rb", "User.create")

    index = described_class.new([f1])

    expect(index.files_referencing("Admin::User")).to contain_exactly(f1)
  end

  it "retorna array vazio para classe não referenciada" do
    f1 = write_file("a.rb", "puts 'hello'")

    index = described_class.new([f1])

    expect(index.files_referencing("Post")).to be_empty
  end

  it "ignora arquivos inexistentes sem erro" do
    index = described_class.new(["/nonexistent/path.rb"])

    expect(index.files_referencing("Foo")).to be_empty
  end

  it "indexa constantes com underscore no nome" do
    # `_` faz parte do nome da constante. Um scan que quebra em `_` perde
    # o nome cheio e o arquivo nunca é encontrado como referenciador.
    f1 = write_file("a.rb", "Post_Assignment.new(1)")
    f2 = write_file("b.rb", "HTTP_Client.get('/')")

    index = described_class.new([f1, f2])

    expect(index.files_referencing("Post_Assignment")).to contain_exactly(f1)
    expect(index.files_referencing("HTTP_Client")).to contain_exactly(f2)
  end

  it "encontra o caller de um proxy de associação underscored (rbs_rails)" do
    # Regressão do bug real: a proxy owner-específica do rbs_rails é
    # construída num arquivo (`Post.rb`), e sua inferência de `initialize`
    # depende de achar esse `.new`. O nome cheio é todo underscored.
    caller = write_file(
      "post.rb",
      "Post_Assignment::ActiveRecord_Associations_CollectionProxy.new(Assignment, self)"
    )

    index = described_class.new([caller])

    expect(
      index.files_referencing("Post_Assignment::ActiveRecord_Associations_CollectionProxy")
    ).to contain_exactly(caller)
  end

  # felixefelip/rbs_infer#131: a caller that reaches the target through a value —
  # a view ivar, a local, a `Current.<attr>` — never spells the class name, so the
  # constant index cannot find it. The method name is the only trace left.
  describe "#files_calling" do
    it "encontra o caller por método chamado, sem a constante no arquivo" do
      view = write_file("show.html.erb", "<%= Current.caderneta.qtde_por_vacina(vacina) %>")

      index = described_class.new([view])

      expect(index.files_referencing("Caderneta")).to be_empty
      expect(index.files_calling("qtde_por_vacina")).to contain_exactly(view)
    end

    it "indexa cada elo de uma cadeia de chamadas" do
      f = write_file("a.rb", "Current.user.posts_titled_like(post)")

      index = described_class.new([f])

      expect(index.files_calling("user")).to contain_exactly(f)
      expect(index.files_calling("posts_titled_like")).to contain_exactly(f)
    end

    it "indexa predicados e bangs" do
      f = write_file("a.rb", "account.matches?(post); record.save!")

      index = described_class.new([f])

      expect(index.files_calling("matches?")).to contain_exactly(f)
      expect(index.files_calling("save!")).to contain_exactly(f)
    end

    # Only explicit-receiver calls. A bare call has no `.` to key on, and is served by
    # the mixin graph (`files_reaching`) or, for a target the ancestor graph puts behind
    # every object, by `#files_with_bare_call`.
    it "não indexa chamadas sem receiver" do
      f = write_file("a.rb", "qtde_por_vacina(vacina)")

      index = described_class.new([f])

      expect(index.files_calling("qtde_por_vacina")).to be_empty
    end

    it "retorna array vazio para método não chamado" do
      f = write_file("a.rb", "puts 'hello'")

      index = described_class.new([f])

      expect(index.files_calling("whatever")).to be_empty
    end

    # `record.channel = "none"` é uma chamada a `channel=`, e só esse nome é
    # consultado: um reader não tem parâmetro, e `files_calling` só é perguntado
    # sobre métodos que têm. Indexando apenas `channel`, um writer ficava
    # invisível — a não ser que a classe tivesse OUTRO método com parâmetros
    # chamado no mesmo arquivo, o que fazia a falha parecer intermitente.
    it "indexa a escrita de atributo sob o nome do writer" do
      f = write_file("a.rb", 'record.channel = "none"')

      index = described_class.new([f])

      expect(index.files_calling("channel=")).to contain_exactly(f)
      expect(index.files_calling("channel")).to contain_exactly(f)
    end

    it "indexa op-assign como escrita e como leitura" do
      f = write_file("a.rb", "counter.total += 1\nsetting.theme ||= 'dark'")

      index = described_class.new([f])

      expect(index.files_calling("total=")).to contain_exactly(f)
      expect(index.files_calling("theme=")).to contain_exactly(f)
    end

    # Comparação é leitura do getter, não escrita: indexar `==`/`=~`/`>=` como
    # writer encheria o índice de nomes que ninguém define.
    it "não confunde comparação com escrita" do
      f = write_file("a.rb", "a.slot == 1 && a.other != 2 && a.third =~ /x/ && a.fourth >= 3")

      index = described_class.new([f])

      %w[slot= other= third= fourth=].each do |name|
        expect(index.files_calling(name)).to be_empty
      end
    end

    # A literal-name `send` is a call to the method it NAMES, and that name is not written
    # after a dot — so the file was indexed under `send`, a name no caller asks about, and
    # the call site was invisible (felixefelip/rbs_infer#205).
    context "com um `send` de nome literal" do
      it "indexa sob o método nomeado, nas três grafias" do
        f = write_file("caller.rb", <<~RUBY)
          x.send(:stamp, "post")
          y.__send__("branded", 1)
          z.public_send(:called)
        RUBY

        index = described_class.new([f])

        expect(index.files_calling("stamp")).to contain_exactly(f)
        expect(index.files_calling("branded")).to contain_exactly(f)
        expect(index.files_calling("called")).to contain_exactly(f)
      end

      it "aceita a forma sem parênteses" do
        f = write_file("caller.rb", "x.send :stamp, \"post\"\n")

        expect(described_class.new([f]).files_calling("stamp")).to contain_exactly(f)
      end

      it "preserva o nome real de um predicado e de um writer" do
        f = write_file("caller.rb", "x.send(:stamped?, \"s\")\nx.send(:title=, \"t\")\n")

        index = described_class.new([f])

        expect(index.files_calling("stamped?")).to contain_exactly(f)
        expect(index.files_calling("title=")).to contain_exactly(f)
      end

      # The limit case: the name is a value, so nothing static says which method it is.
      # Indexing it under *something* would send the analyzer to a file that never calls it.
      it "ignora um nome computado" do
        f = write_file("caller.rb", <<~'RUBY')
          x.send(name)
          x.send(:"ti#{part}")
          x.send(SOME_CONST)
        RUBY

        index = described_class.new([f])

        expect(index.files_calling("name")).to be_empty
        expect(index.files_calling("part")).to be_empty
      end

      # `\b` before the alternation: a method whose name merely ENDS in `send` is not one.
      it "não confunde um método cujo nome termina em send" do
        f = write_file("caller.rb", "x.resend(:stamp)\n")

        expect(described_class.new([f]).files_calling("stamp")).to be_empty
      end

      # The quote group of the string form comes back from `scan` too; it is never a name.
      it "não indexa a aspa da forma com string" do
        f = write_file("caller.rb", "x.send(\"stamp\")\n")

        index = described_class.new([f])

        expect(index.files_calling("stamp")).to contain_exactly(f)
        expect(index.files_calling("\"")).to be_empty
      end
    end
  end

  # The bare form, scanned on demand instead of indexed: `include Foo` in a class body is
  # `Module#include` on the class object, and neither index above can find it — the file
  # names no target, and there is no `.` to key on.
  describe "#files_with_bare_call" do
    it "encontra a chamada sem receiver no começo da linha" do
      f = write_file("host.rb", "class Host\n  include Hookable\nend\n")

      expect(described_class.new([f]).files_with_bare_call("include")).to contain_exactly(f)
    end

    it "ignora a forma com receiver, que o índice de chamadas já cobre" do
      f = write_file("a.rb", "Host.include Hookable\n")

      expect(described_class.new([f]).files_with_bare_call("include")).to be_empty
    end

    it "ignora uma atribuição ao mesmo nome" do
      f = write_file("a.rb", "include = 1\n")

      expect(described_class.new([f]).files_with_bare_call("include")).to be_empty
    end

    # A definição não é uma chamada — e é justamente o arquivo do alvo, que assim seria
    # analisado como caller de si mesmo.
    it "ignora a própria definição do método" do
      f = write_file("module_reopen.rb", "class Module\n  def include(*modules)\n    modules\n  end\nend\n")

      expect(described_class.new([f]).files_with_bare_call("include")).to be_empty
    end

    it "ignora comentário" do
      f = write_file("a.rb", "# include Hookable\n")

      expect(described_class.new([f]).files_with_bare_call("include")).to be_empty
    end
  end

  it "não confunde constantes CamelCase adjacentes a underscores" do
    # `Foo_Bar` é uma constante distinta de `Foo` e de `Bar`; o lookup por
    # `Foo` não deve casar o arquivo que só referencia `Foo_Bar`.
    f1 = write_file("a.rb", "Foo_Bar.new")

    index = described_class.new([f1])

    expect(index.files_referencing("Foo_Bar")).to contain_exactly(f1)
    expect(index.files_referencing("Foo")).to be_empty
    expect(index.files_referencing("Bar")).to be_empty
  end
end
