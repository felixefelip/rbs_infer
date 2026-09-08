# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/jobs/runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Extensions::Rails::Jobs::RuntimeGenerator do
  def in_app(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, content|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield dir
    end
  end

  def build(files)
    in_app(files) { |dir| described_class.new(app_dir: dir).build }
  end

  APPLICATION_JOB = <<~RUBY
    class ApplicationJob < ActiveJob::Base
    end
  RUBY

  it "reopens ActiveJob::Base and forwards the enqueue arguments to `perform`" do
    source = build("app/jobs/application_job.rb" => APPLICATION_JOB).first[:source]

    expect(source).to include("class ActiveJob::Base\n")
    expect(source).to include("def self.perform_later(*args, **kwargs)")
    expect(source).to include("new.perform(*args, **kwargs)")
  end

  it "ends the forward on `new`, the job `perform_later` actually returns" do
    source = build("app/jobs/application_job.rb" => APPLICATION_JOB).first[:source]

    body = source[/def self\.perform_later.*?\n  end/m]
    expect(body.lines.last(2).first.strip).to eq("new")
  end

  it "emits one file, named for the class it reopens" do
    files = build("app/jobs/application_job.rb" => APPLICATION_JOB)

    expect(files.map { |f| f[:filename] }).to eq(["active_job_base.rb"])
  end

  it "emits nothing when no class subclasses ActiveJob::Base" do
    expect(build("app/models/user.rb" => "class User; end")).to be_empty
  end

  it "does not fire on a mere mention of ActiveJob::Base" do
    files = build("app/jobs/notes.rb" => "# ActiveJob::Base is the superclass\nclass Notes; end\n")

    expect(files).to be_empty
  end

  it "removes a stale sidecar dir when the app no longer qualifies" do
    in_app("app/models/user.rb" => "class User; end") do |dir|
      sidecar = File.join(dir, described_class::SIDECAR_DIR)
      FileUtils.mkdir_p(sidecar)
      File.write(File.join(sidecar, "active_job_base.rb"), "# stale")

      described_class.new(app_dir: dir).generate

      expect(Dir.exist?(sidecar)).to be(false)
    end
  end

  it "writes the sidecar under sig/generated/steep_activejob_runtime/" do
    in_app("app/jobs/application_job.rb" => APPLICATION_JOB) do |dir|
      path = described_class.new(app_dir: dir).generate

      expect(path).to eq(File.join(dir, "sig/generated/steep_activejob_runtime"))
      expect(File.exist?(File.join(path, "active_job_base.rb"))).to be(true)
    end
  end
end
