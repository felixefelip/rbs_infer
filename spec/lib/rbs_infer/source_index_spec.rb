require "spec_helper"
require "rbs_infer"
require "tmpdir"

RSpec.describe RbsInfer::Analyzer::SourceIndex do
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
end
