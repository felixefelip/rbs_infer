# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require "yaml"

# What a `class_eval` of a string defines is written as checked Ruby, so
# `steep check` reads the bodies — preconditions, narrowing and diagnostics —
# and this pipeline reads them as one more file of the corpus.
RSpec.describe RbsInfer::Project::StringEvalSources do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def sidecar(call_sites)
    write(RbsInfer::Project::StringEvalSidecar::PATH, { "version" => 2, "call_sites" => call_sites }.to_yaml)
    RbsInfer::Project::StringEvalSidecar.load(Dir.pwd)
  end

  def generate(call_sites)
    described_class.generate(base_dir: Dir.pwd, sidecar: sidecar(call_sites))
  end

  let(:output) { "sig/generated/steep_string_evals/app/models/post.rb" }

  before do
    write("app/models/post.rb", <<~RUBY)
      class Post
        delegate :email, to: :user, prefix: true
      end
    RUBY
  end

  it "writes the methods a call site defines, in the class that made the call" do
    written = generate("app/models/post.rb:2:2" => ["def user_email(...)\n  _ = user\n  _.email(...)\nend\n"])

    expect(written).to eq([File.expand_path(output)])
    expect(File.read(output)).to include(<<~RUBY)
      class Post
        def user_email(...)
          _ = user
          _.email(...)
        end
      end
    RUBY
  end

  it "drops the file of a call site that is gone" do
    generate("app/models/post.rb:2:2" => ["def user_email(...)\nend\n"])
    generate({})

    expect(File).not_to exist(output)
  end

  it "writes nothing for a file the sidecar names but the project does not have" do
    expect(generate("app/models/gone.rb:2:2" => ["def x\nend\n"])).to be_empty
  end

  it "lists the files that make the recorded calls" do
    loaded = sidecar("app/models/post.rb:2:2" => ["def a\nend\n"], "app/models/post.rb:3:2" => ["def b\nend\n"],
                     "lib/x.rb:1:0" => ["def c\nend\n"])

    expect(loaded.paths).to eq(%w[app/models/post.rb lib/x.rb])
  end
end
