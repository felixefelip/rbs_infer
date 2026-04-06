require "spec_helper"
require "rbs_infer"
require "tmpdir"

RSpec.describe RbsInfer::ParseCache do
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

  it "retorna entry com source e result para arquivo válido" do
    file = write_file("user.rb", "class User; end")
    cache = described_class.new

    entry = cache.get(file)

    expect(entry).not_to be_nil
    expect(entry.source).to eq("class User; end")
    expect(entry.result).to be_a(Prism::ParseResult)
  end

  it "parseia o arquivo apenas uma vez mesmo com múltiplas chamadas" do
    file = write_file("user.rb", "class User; end")
    cache = described_class.new

    expect(File).to receive(:read).with(file).once.and_call_original

    3.times { cache.get(file) }
  end

  it "retorna o mesmo objeto nas chamadas subsequentes" do
    file = write_file("user.rb", "class User; end")
    cache = described_class.new

    entry1 = cache.get(file)
    entry2 = cache.get(file)

    expect(entry1).to equal(entry2)
  end

  it "retorna nil para arquivo inexistente" do
    cache = described_class.new

    expect(cache.get("/nonexistent/file.rb")).to be_nil
  end

  it "retorna nil para arquivo sem permissão de leitura" do
    file = write_file("secret.rb", "class Secret; end")
    File.chmod(0o000, file)
    cache = described_class.new

    expect(cache.get(file)).to be_nil
  ensure
    File.chmod(0o644, file)
  end

  it "cacheia diferentes arquivos independentemente" do
    file1 = write_file("user.rb", "class User; end")
    file2 = write_file("post.rb", "class Post; end")
    cache = described_class.new

    entry1 = cache.get(file1)
    entry2 = cache.get(file2)

    expect(entry1.source).to eq("class User; end")
    expect(entry2.source).to eq("class Post; end")
  end
end
