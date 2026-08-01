require "spec_helper"
require "rbs_infer"
require "action_controller"
require "tmpdir"
require "rbs_infer/extensions/rails/controllers/framework_source_transcriber"

RSpec.describe RbsInfer::Extensions::Rails::Controllers::FrameworkSourceTranscriber do
  subject(:source) { described_class.new.build }

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
    first, *rest = node.slice.lines
    ([first] + rest.map { |l| l.strip.empty? ? l : l.sub(/\A {0,#{margin}}/, "") }).join
  end

  it "transcribes the body verbatim from the installed gem" do
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

      expect(quiet.build.map(&:filename)).not_to include(described_class::FILENAME)
      expect(asked.build.map(&:filename)).to include(described_class::FILENAME)
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

    expect(described_class.new.build).to be_nil
  end
end
