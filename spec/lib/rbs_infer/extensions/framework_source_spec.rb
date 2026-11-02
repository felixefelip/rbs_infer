# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/framework_source"

RSpec.describe RbsInfer::Extensions::FrameworkSource do
  describe ".mark_defs" do
    it "puts the marker above every def, at its indentation" do
      source = "module A\n  def a; end\n\n  class B\n    def self.b = 1\n  end\nend\n"

      expect(described_class.mark_defs(source, "# mark")).to eq(
        "module A\n  # mark\n  def a; end\n\n  class B\n    # mark\n    def self.b = 1\n  end\nend\n"
      )
    end
  end

  describe ".without_requires" do
    it "drops the top-level requires and keeps the rest" do
      source = "require \"a\"\nrequire_relative \"b\"\n\nmodule A\n  require \"c\"\nend\n"

      expect(described_class.without_requires(source)).to eq("\nmodule A\n  require \"c\"\nend\n")
    end

    it "keeps a require with a receiver" do
      source = "Kernel.require \"a\"\n"

      expect(described_class.without_requires(source)).to eq(source)
    end
  end
end
