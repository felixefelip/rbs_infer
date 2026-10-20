# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe "a constant another signature already declares" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def write_lib
    write("lib/lib.rb", <<~RUBY)
      class Lib
        KINDS = [:a, :b].freeze
        LIMIT = 3

        module Options
          VALID = [:x].freeze
        end
      end
    RUBY
  end

  def lib_rbs
    RbsInfer::Analyzer.new(target_class: "Lib", target_file: "lib/lib.rb",
                           source_files: Dir["lib/*.rb"]).generate_rbs
  end

  it "is left to that signature" do
    write_lib
    write("sig/vendor/lib.rbs", <<~RBS)
      class Lib
        KINDS: Array[Symbol]
      end
    RBS

    rbs = lib_rbs
    expect(rbs).not_to include("KINDS")
    expect(rbs).to include("LIMIT: Integer")
  end

  it "is left to that signature when it belongs to a nested module" do
    write_lib
    write("sig/vendor/lib.rbs", <<~RBS)
      class Lib
        module Options
          VALID: Array[Symbol]
        end
      end
    RBS

    expect(lib_rbs).not_to include("VALID")
  end

  it "is still declared when only the previous output of the same file declares it" do
    write_lib
    write("sig/generated/lib/lib.rbs", <<~RBS)
      class Lib
        KINDS: Array[Symbol]
      end
    RBS

    expect(lib_rbs).to include("KINDS: ")
  end
end
