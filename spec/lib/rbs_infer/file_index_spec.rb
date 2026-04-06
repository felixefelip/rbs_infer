require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::FileIndex do
  it "encontra arquivo por class_path exato" do
    file = "/project/app/models/user.rb"
    index = described_class.new([file])

    expect(index.find("user")).to eq(file)
    expect(index.find("models/user")).to eq(file)
    expect(index.find("app/models/user")).to eq(file)
  end

  it "encontra arquivo por class_path com namespace" do
    file = "/project/app/models/account/import.rb"
    index = described_class.new([file])

    expect(index.find("account/import")).to eq(file)
    expect(index.find("models/account/import")).to eq(file)
  end

  it "retorna nil para class_path inexistente" do
    index = described_class.new(["/project/app/models/user.rb"])

    expect(index.find("post")).to be_nil
    expect(index.find("app/models/post")).to be_nil
  end

  it "não confunde sufixos parciais (sem falsos positivos)" do
    files = [
      "/project/app/models/magic_link.rb",
      "/project/app/models/via_magic_link.rb"
    ]
    index = described_class.new(files)

    # "magic_link" deve encontrar magic_link.rb, não via_magic_link.rb
    result = index.find("magic_link")
    expect(result).to eq("/project/app/models/magic_link.rb")
  end

  it "#include? retorna true para class_path existente" do
    index = described_class.new(["/project/app/models/user.rb"])

    expect(index.include?("user")).to be true
    expect(index.include?("models/user")).to be true
  end

  it "#include? retorna false para class_path inexistente" do
    index = described_class.new(["/project/app/models/user.rb"])

    expect(index.include?("post")).to be false
  end

  it "lida com lista de arquivos vazia" do
    index = described_class.new([])

    expect(index.find("user")).to be_nil
    expect(index.include?("user")).to be false
  end

  it "indexa múltiplos arquivos" do
    user_file = "/project/app/models/user.rb"
    post_file = "/project/app/models/post.rb"
    index = described_class.new([user_file, post_file])

    expect(index.find("user")).to eq(user_file)
    expect(index.find("post")).to eq(post_file)
  end
end
