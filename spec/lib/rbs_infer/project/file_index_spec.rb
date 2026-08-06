require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::FileIndex do
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

  # A suffix is not unique, and the file `find` lands on may declare a different
  # class: `app/models/account/export.rb` (`class Account::Export`) answers to
  # "export" as much as `app/models/export.rb` does. A caller that parses the
  # file and can TELL walks the candidates (felixefelip/rbs_infer#185).
  describe "#candidates" do
    let(:nested) { "/project/app/models/account/export.rb" }
    let(:top_level) { "/project/app/models/export.rb" }

    it "returns every file whose path ends in the class_path" do
      index = described_class.new([nested, top_level])

      expect(index.candidates("export")).to contain_exactly(nested, top_level)
    end

    # The conventional home of a top-level constant is the least-nested path,
    # whatever order the files were indexed in.
    it "orders the least-nested path first" do
      expect(described_class.new([nested, top_level]).candidates("export").first).to eq(top_level)
      expect(described_class.new([top_level, nested]).candidates("export").first).to eq(top_level)
    end

    it "returns [] for a class_path nothing answers to" do
      expect(described_class.new([top_level]).candidates("post")).to eq([])
    end

    # `find` is `candidates.first`, so the ambiguous case now answers with the
    # top-level file rather than with whichever was indexed first.
    it "agrees with #find" do
      index = described_class.new([nested, top_level])

      expect(index.find("export")).to eq(top_level)
    end
  end

  # The path a constant implies is guessed by splitting on case changes, without
  # the app's `inflect.acronym` rules — `SQLite` becomes `sq_lite` while the file
  # is `sqlite.rb` (felixefelip/rbs_infer#185).
  describe "a class_path whose word breaks do not match the file's" do
    let(:file) { "/project/app/models/search/record/sqlite/fts.rb" }

    it "finds the file with the word breaks squashed out" do
      index = described_class.new([file])

      expect(index.find("search/record/sq_lite/fts")).to eq(file)
      expect(index.include?("search/record/sq_lite/fts")).to be true
    end

    it "matches whichever side carries the underscore" do
      index = described_class.new(["/project/app/models/http_client.rb"])

      expect(index.find("httpclient")).to eq("/project/app/models/http_client.rb")
    end

    # Only ever consulted on a miss, so a lookup that already succeeded keeps its
    # answer even when a squashed key would match something else.
    it "prefers an exact suffix match" do
      exact = "/project/app/models/magic_link.rb"
      squashed = "/project/app/lib/magiclink.rb"
      index = described_class.new([squashed, exact])

      expect(index.find("magic_link")).to eq(exact)
    end

    it "still returns nil when nothing matches either way" do
      expect(described_class.new([file]).find("search/record/sq_lite/other")).to be_nil
    end
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
