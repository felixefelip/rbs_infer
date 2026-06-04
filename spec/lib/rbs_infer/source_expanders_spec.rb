# frozen_string_literal: true

require "spec_helper"

RSpec.describe RbsInfer::SourceExpanders do
  # Test expanders are registered/unregistered per example so no state
  # leaks into the global registry (which already holds the defaults).
  let(:upcase_class_expander) do
    Module.new do
      def self.expand(source)
        source.include?("klass") ? source.gsub("klass", "Klass") : nil
      end
    end
  end

  let(:noop_expander) do
    Module.new do
      def self.expand(_source) = nil
    end
  end

  after do
    described_class.unregister(upcase_class_expander)
    described_class.unregister(noop_expander)
  end

  it "registers the default CurrentAttributes expander" do
    expect(described_class.expanders)
      .to include(RbsInfer::Extensions::Rails::CurrentAttributesExpander)
  end

  it "returns nil when no expander changes the source" do
    described_class.register(noop_expander)

    expect(described_class.apply("class Foo; end")).to be_nil
  end

  it "returns the expanded source when an expander applies" do
    described_class.register(upcase_class_expander)

    expect(described_class.apply("klass Foo")).to eq("Klass Foo")
  end

  it "chains expanders, feeding one's output to the next" do
    first = Module.new do
      def self.expand(source)
        source.include?("AAA") ? source.gsub("AAA", "BBB") : nil
      end
    end
    second = Module.new do
      def self.expand(source)
        source.include?("BBB") ? source.gsub("BBB", "CCC") : nil
      end
    end

    described_class.register(first)
    described_class.register(second)
    begin
      expect(described_class.apply("AAA")).to eq("CCC")
    ensure
      described_class.unregister(first)
      described_class.unregister(second)
    end
  end

  it "does not register the same expander twice" do
    described_class.register(noop_expander)
    described_class.register(noop_expander)

    expect(described_class.expanders.count { |e| e == noop_expander }).to eq(1)
  end
end
