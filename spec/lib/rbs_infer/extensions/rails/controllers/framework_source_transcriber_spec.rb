require "spec_helper"
require "rbs_infer"
require "action_controller"
require "tmpdir"
require "rbs_infer/extensions/rails/controllers/framework_source_transcriber"
require "rbs_infer/extensions/rails/controllers/runtime_generator"

RSpec.describe RbsInfer::Extensions::Rails::Controllers::FrameworkSourceTranscriber do
  subject(:source) { files.map { |f| f[:source] }.join("\n") }

  let(:files) { described_class.new.build }

  it "mirrors the gem's own path, so provenance is readable from it" do
    expect(files.map { |f| f[:filename] })
      .to contain_exactly("action_controller/metal/http_authentication.rb", "action_controller/base.rb")
  end

  # The point of transcribing rather than modelling is that the body is the
  # gem's, whatever version happens to be installed. So the assertions below
  # compare against the RESOLVED source rather than against a fixed text, which
  # would pin a Rails version instead of the property that matters.
  def real_body(receiver, method_name)
    method = Object.const_get(receiver).instance_method(method_name)
    file, line = method.source_location
    result = Prism.parse_file(file)
    node = RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::DefNode) }
                             .find { |n| n.location.start_line == line }
    margin = node.location.start_column
    # Desugared like the transcription itself, so a dynamic send does not read
    # as a discrepancy: the body is the gem's MODULO the one declared rewrite
    # (felixefelip/rbs_infer#160). Without this the assertion below turns into a
    # landmine — it passes only while no seed's body contains a `__send__`.
    first, *rest = described_class.new.send(:desugar_dynamic_sends, node).lines
    ([first] + rest.map { |l| l.strip.empty? ? l : l.sub(/\A {0,#{margin}}/, "") }).join
  end

  it "transcribes the body from the installed gem, modulo the declared rewrite" do
    body = real_body(
      "ActionController::HttpAuthentication::Token::ControllerMethods",
      :authenticate_or_request_with_http_token
    )

    # Every line of the real method, at the sidecar's indentation.
    body.lines.each do |line|
      next if line.strip.empty?

      expect(source).to include(line.strip)
    end
  end

  it "keeps each body in the owner it was written in" do
    # Not a free choice: a body carries constant references that resolve by the
    # lexical nesting of where it was WRITTEN. `Token.authenticate(...)` moved
    # into `ActionController::Base` stops resolving — there is no
    # `ActionController::Token` — and Ruby raises the same NameError the checker
    # reports. Declarations have a free owner; bodies do not.
    expect(source).to include("module Token\n      module ControllerMethods\n")
    expect(source).to include("def authenticate_or_request_with_http_token")
    expect(source).to include("def authenticate_with_http_token")
  end

  # The `||`'s other operand, and the frame that hands `self` to it. Their TYPES
  # were never in question — what is missing without them is the proof that
  # reaching this operand RENDERS, which is what makes the fact the block
  # establishes sound on every other exit (felixefelip/steep#126).
  it "transcribes the halting tail of the chain" do
    expect(source).to include("def request_http_token_authentication")

    real_body("ActionController::HttpAuthentication::Token", :authentication_request).lines.each do |line|
      next if line.strip.empty?

      expect(source).to include(line.strip)
    end
  end

  # felixefelip/rbs_infer#165. A transcribed module is a mixin, and its body runs
  # with the includer's `self` — which the module cannot state, so the
  # transcription states it, twice, once for each reader.
  describe "who includes the transcribed module" do
    let(:host) { "ActionController::Base" }
    let(:mixin) { "ActionController::HttpAuthentication::Token::ControllerMethods" }

    # For whatever reads Ruby: a file of its own, because a file's includes are
    # attributed to the ONE class it declares, and the transcription declares
    # several modules.
    it "emits the include as Ruby, in the host's own file" do
      base = files.find { |f| f[:filename] == "action_controller/base.rb" }

      expect(base[:source]).to include("module ActionController\n  class Base\n")
      expect(base[:source]).to include("include #{mixin}")
    end

    # For the checker: without it every `self` handed out of the module is a
    # bare module, and passing one where the callee declares a controller is an
    # error the real code does not have.
    it "annotates the module's own self type" do
      expect(source).to include("# @type instance: #{host} & #{mixin}")
    end

    # Curated like the seeds, but confirmed against the loaded runtime, so a
    # Rails version that rearranges its mixins drops the claim instead of
    # repeating it.
    it "emits nothing for a mixin the runtime does not confirm" do
      stub_const(
        "#{described_class}::MIXINS",
        [described_class::Mixin.new(host: "ActionController::Base", module_name: "Comparable")]
      )

      expect(files.map { |f| f[:filename] }).not_to include("action_controller/base.rb")
      expect(source).not_to include("@type instance:")
    end
  end

  # And the rewrite is not hypothetical: that render is written as a dynamic
  # send, so a verbatim transcription would be a dead end at exactly the point
  # where the halt has to be seen.
  it "leaves no dynamic send behind" do
    # The header names the rewrite, so the assertion is about the code below it.
    code = source.lines.reject { |line| line.start_with?("#") }.join

    expect(code).to include("controller.render")
    expect(code).not_to include("__send__")
  end

  it "rewrites nothing, not even a def line" do
    body = real_body("ActionController::HttpAuthentication::Token", :authenticate)

    expect(body).to start_with("def authenticate(")
    expect(source).to include("def authenticate(controller, &login_procedure)")
    expect(source).to include("login_procedure.call(token, options)")
    expect(source).not_to include("def self.authenticate")
  end

  it "emits parseable Ruby" do
    expect { Prism.parse(source).value }.not_to raise_error
    expect(Prism.parse(source).success?).to be(true)
  end

  it "is emitted by the controller runtime generator only when asked" do
    # Not detected from whether Rails happens to be loaded: that would make the
    # sidecar's content depend on the process rather than on intent.
    Dir.mktmpdir do |dir|
      quiet = RbsInfer::Extensions::Rails::Controllers::RuntimeGenerator.new(app_dir: dir)
      asked = RbsInfer::Extensions::Rails::Controllers::RuntimeGenerator.new(app_dir: dir, transcribe_framework: true)

      transcribed = "action_controller/metal/http_authentication.rb"
      expect(quiet.build.map(&:filename)).not_to include(transcribed)
      expect(asked.build.map(&:filename)).to include(transcribed)
    end
  end

  it "skips a seed it cannot resolve instead of raising" do
    stub_const(
      "#{described_class}::SEEDS",
      [described_class::Seed.new(
        receiver: "ActionController::Base",
        method_name: :no_such_method_anywhere
      )]
    )

    stub_const("#{described_class}::MIXINS", [])

    expect(described_class.new.build).to be_empty
  end

  # felixefelip/rbs_infer#160. The one deviation from a verbatim body, applied
  # because Steep resolves NONE of `__send__`, `send`, `public_send` — all three
  # type as their `Kernel`/`BasicObject` declaration and return `untyped`, so the
  # call is a dead end for the flow the transcription exists to expose.
  describe "desugaring a dynamic send" do
    def desugar(ruby)
      node = RbsInfer::Analyzer.find_all_nodes(Prism.parse(ruby).value) { |n| n.is_a?(Prism::DefNode) }.first
      described_class.new.send(:desugar_dynamic_sends, node)
    end

    it "writes the call without the indirection, keeping the other arguments" do
      expect(desugar(<<~RUBY)).to include("controller.render plain: message, status: :unauthorized")
        def authentication_request(controller, message)
          controller.__send__ :render, plain: message, status: :unauthorized
        end
      RUBY
    end

    it "covers `send` and `public_send`, which resolve no better" do
      expect(desugar("def a(c); c.send(:render, 1); end")).to include("c.render(1)")
      expect(desugar("def a(c); c.public_send(:render, 1); end")).to include("c.render(1)")
    end

    it "handles a call whose only argument is the symbol" do
      expect(desugar("def a(c); c.__send__(:reset); end")).to include("c.reset()")
    end

    # With a variable there is no name to put in the message's place, so the
    # call stays as written — and stays a dead end, honestly.
    it "leaves a dynamic name alone" do
      expect(desugar("def a(c, name); c.__send__(name, 1); end")).to include("c.__send__(name, 1)")
    end

    it "leaves an ordinary call alone" do
      expect(desugar("def a(c); c.render(1); end")).to include("c.render(1)")
    end
  end
end
