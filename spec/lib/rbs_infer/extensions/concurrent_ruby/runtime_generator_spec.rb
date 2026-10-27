# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/concurrent_ruby/runtime_generator"
require "tmpdir"

RSpec.describe RbsInfer::Extensions::ConcurrentRuby::RuntimeGenerator do
  def files
    @files ||= described_class.new(app_dir: ".").build
  end

  def source_of(filename) = files.find { |file| file[:filename] == filename }[:source]

  def gem_file(filename)
    File.read(File.join(Gem.loaded_specs["concurrent-ruby"].full_gem_path, "lib", "concurrent-ruby", filename))
  end

  it "emits the files `require \"concurrent/map\"` loads, in load order" do
    expect(files.map { |file| file[:filename] }).to eq(
      %w[concurrent/constants.rb concurrent/utility/engine.rb
         concurrent/collection/map/non_concurrent_map_backend.rb
         concurrent/collection/map/mri_map_backend.rb concurrent/map.rb]
    )
  end

  it "leaves out the backends another engine would load" do
    expect(files.map { |file| file[:filename] }.grep(/jruby|truffleruby|synchronized/)).to be_empty
  end

  it "transcribes each file verbatim under the header, but for the marks" do
    unmarked = source_of("concurrent/map.rb").gsub(/^ *#{Regexp.escape(described_class::OVERLOAD_MARKER)}\n/, "")

    expect(unmarked).to eq(described_class::HEADER + gem_file("concurrent/map.rb"))
  end

  it "marks every def as overloading, at the def's indentation" do
    source = source_of("concurrent/collection/map/non_concurrent_map_backend.rb")

    expect(source).to include("      # @rbs_infer |...\n      def [](key)\n")
    expect(source.scan(/^ *def /).size).to eq(source.scan(/^ *# @rbs_infer \|\.\.\.\n *def /).size)
  end

  describe "#generate" do
    it "writes each file at its path under the gem's lib, dropping a stale sidecar" do
      Dir.mktmpdir do |dir|
        stale = File.join(dir, described_class::SIDECAR_DIR, "concurrent/gone.rb")
        FileUtils.mkdir_p(File.dirname(stale))
        File.write(stale, "")

        sidecar = described_class.new(app_dir: dir).generate

        expect(File.read(File.join(sidecar, "concurrent/collection/map/mri_map_backend.rb")))
          .to include("class MriMapBackend < NonConcurrentMapBackend")
        expect(File).not_to exist(stale)
      end
    end
  end
end
