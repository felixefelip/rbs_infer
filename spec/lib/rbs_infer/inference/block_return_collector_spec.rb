require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::BlockReturnCollector do
  # Steep's map is keyed `"line:column"`; the fixtures below state it directly so
  # the collector's own job — finding the block's last statement and looking it
  # up — is what gets tested, not the bridge.
  def collect(source, methods:, expression_types:, receiver_check: nil)
    collector = described_class.new(
      methods: Set.new(methods), expression_types: expression_types, receiver_check: receiver_check
    )
    Prism.parse(source).value.accept(collector)
    collector.returns
  end

  it "reads the type of the block's last statement" do
    source = <<~RUBY
      def go
        with_token do |token|
          lookup(token)
        end
      end
    RUBY

    expect(collect(source, methods: ["with_token"], expression_types: { "3:4" => "User?" }))
      .to eq("with_token" => ["User?"])
  end

  it "records one entry per call site, for the caller to union" do
    source = <<~RUBY
      def go
        wrap { 1 }
        wrap { "x" }
      end
    RUBY

    expect(collect(source, methods: ["wrap"], expression_types: { "2:9" => "Integer", "3:9" => "String" }))
      .to eq("wrap" => ["Integer", "String"])
  end

  # A call with a receiver is somebody else's method until proven otherwise. The
  # target's own file passes no check, where a receiverless call is a self-send.
  it "ignores a call on a receiver when no check is supplied" do
    source = "def go; other.wrap { 1 }; end"

    expect(collect(source, methods: ["wrap"], expression_types: { "1:21" => "Integer" })).to be_empty
  end

  it "asks the supplied check about a receiver" do
    source = "def go; other.wrap { 1 }; end"

    expect(collect(source, methods: ["wrap"], expression_types: { "1:21" => "Integer" }, receiver_check: ->(_node) { true }))
      .to eq("wrap" => ["Integer"])
  end

  it "says nothing about a site the checker could not type" do
    source = "def go; wrap { compute }; end"

    expect(collect(source, methods: ["wrap"], expression_types: {})).to be_empty
  end

  it "ignores a call with no block at all" do
    expect(collect("def go; wrap(1); end", methods: ["wrap"], expression_types: { "1:13" => "Integer" })).to be_empty
  end
end
