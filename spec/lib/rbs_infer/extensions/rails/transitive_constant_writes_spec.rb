# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/transitive_constant_writes"
require "prism"

RSpec.describe RbsInfer::Extensions::Rails::TransitiveConstantWrites do
  # Parses a `def user=(value) ... end` body and runs extraction.
  def extract(body)
    src = "def user=(value)\n#{body}\nend\n"
    defn = Prism.parse(src).value.statements.body.first
    described_class.extract(defn, "value")
  end

  it "extracts an unconditional self-write deriving from the param" do
    expect(extract("self.caderneta = value.caderneta")).to eq(
      [{ attr: "caderneta", value_method: "caderneta" }]
    )
  end

  it "extracts `self.x = value` (the whole arg) with nil value_method" do
    expect(extract("self.dup = value")).to eq([{ attr: "dup", value_method: nil }])
  end

  it "extracts a write guarded by `unless value.nil?`" do
    expect(extract("self.caderneta = value.caderneta unless value.nil?")).to eq(
      [{ attr: "caderneta", value_method: "caderneta" }]
    )
  end

  it "extracts a write guarded by `if value` (truthiness)" do
    expect(extract("self.caderneta = value.caderneta if value")).to eq(
      [{ attr: "caderneta", value_method: "caderneta" }]
    )
  end

  it "extracts from block-form nil guard" do
    writes = extract(<<~RUBY)
      unless value.nil?
        self.caderneta = value.caderneta
        self.conta = value.conta
      end
    RUBY

    expect(writes).to eq([
      { attr: "caderneta", value_method: "caderneta" },
      { attr: "conta", value_method: "conta" },
    ])
  end

  it "EXCLUDES writes guarded by `if value.present?` (blank gap)" do
    expect(extract("self.caderneta = value.caderneta if value.present?")).to eq([])
  end

  it "excludes writes guarded by an unrelated condition" do
    expect(extract("self.caderneta = value.caderneta if some_flag")).to eq([])
  end

  it "excludes RHS not derived from the param" do
    expect(extract("self.caderneta = Caderneta.find(1)")).to eq([])
    expect(extract("self.caderneta = other.caderneta")).to eq([])
  end

  it "excludes writes with a different nil-check subject" do
    expect(extract("self.caderneta = value.caderneta unless other.nil?")).to eq([])
  end

  it "ignores non-self assignments and super" do
    writes = extract(<<~RUBY)
      super(value)
      @cache = value
      self.caderneta = value.caderneta
    RUBY

    expect(writes).to eq([{ attr: "caderneta", value_method: "caderneta" }])
  end

  it "excludes value.method with arguments (not a plain reader)" do
    expect(extract("self.caderneta = value.fetch(:x)")).to eq([])
  end
end
