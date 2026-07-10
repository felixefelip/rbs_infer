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
