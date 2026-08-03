require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::BlockReturnCollector do
  # Steep's map is keyed by an expression's whole RANGE
  # (`"start_line:start_column-end_line:end_column"`, #168); the fixtures below
  # state it directly so the collector's own job — finding the block's last
  # statement and looking it up — is what gets tested, not the bridge.
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

    expect(collect(source, methods: ["with_token"], expression_types: { "3:4-3:17" => "User?" }))
      .to eq("with_token" => ["User?"])
  end

  it "records one entry per call site, for the caller to union" do
    source = <<~RUBY
      def go
        wrap { 1 }
        wrap { "x" }
      end
    RUBY

    expect(collect(source, methods: ["wrap"], expression_types: { "2:9-2:10" => "Integer", "3:9-3:12" => "String" }))
      .to eq("wrap" => ["Integer", "String"])
  end

  # A call with a receiver is somebody else's method until proven otherwise. The
  # target's own file passes no check, where a receiverless call is a self-send.
  it "ignores a call on a receiver when no check is supplied" do
    source = "def go; other.wrap { 1 }; end"

    expect(collect(source, methods: ["wrap"], expression_types: { "1:21-1:22" => "Integer" })).to be_empty
  end

  it "asks the supplied check about a receiver" do
    source = "def go; other.wrap { 1 }; end"

    expect(collect(source, methods: ["wrap"], expression_types: { "1:21-1:22" => "Integer" }, receiver_check: ->(_node) { true }))
      .to eq("wrap" => ["Integer"])
  end

  it "says nothing about a site the checker could not type" do
    source = "def go; wrap { compute }; end"

    expect(collect(source, methods: ["wrap"], expression_types: {})).to be_empty
  end

  it "ignores a call with no block at all" do
    expect(collect("def go; wrap(1); end", methods: ["wrap"], expression_types: { "1:13" => "Integer" })).to be_empty
  end

  # felixefelip/rbs_infer#158: a forwarded block is not evidence, but it is an
  # EDGE. Every block that reaches the callee through it is one that reached the
  # forwarder, so the caller propagates the forwarder's answer along it.
  describe "#forwards" do
    def forwards_in(source, methods:)
      collector = described_class.new(methods: Set.new(methods), expression_types: {})
      Prism.parse(source).value.accept(collector)
      collector.forwards
    end

    it "records who hands its own block on to whom" do
      source = <<~RUBY
        def with_token(&block)
          fetch_token(&block) || deny
        end
      RUBY

      expect(forwards_in(source, methods: ["fetch_token"])).to eq("with_token" => ["fetch_token"])
    end

    # `other(&:upcase)` builds a proc on the spot and `other(&some_proc)` passes
    # somebody else's — neither says anything about what reached this method.
    it "ignores a block that is not the method's own" do
      source = <<~RUBY
        def wrapper(&block)
          fetch_token(&:upcase)
          fetch_token(&other_proc)
        end
      RUBY

      expect(forwards_in(source, methods: ["fetch_token"])).to be_empty
    end

    it "ignores a forward from outside any method" do
      expect(forwards_in("fetch_token(&block)", methods: ["fetch_token"])).to be_empty
    end
  end
end
