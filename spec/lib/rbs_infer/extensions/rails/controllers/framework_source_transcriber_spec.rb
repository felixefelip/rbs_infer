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
  def real_body(receiver, method_name, singleton: false)
    target = Object.const_get(receiver)
    method = singleton ? target.method(method_name) : target.instance_method(method_name)
    file, line = method.source_location
    result = Prism.parse_file(file)
    node = RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::DefNode) }
                             .find { |n| n.location.start_line == line }
    margin = node.location.start_column
    first, *rest = node.slice.lines
    ([first] + rest.map { |l| l.strip.empty? ? l : l.sub(/\A {0,#{margin}}/, "") }).join
  end

  it "transcribes the body verbatim from the installed gem" do
    body = real_body("ActionController::Base", :authenticate_or_request_with_http_token)

    # Every line of the real method, at the sidecar's indentation.
    body.lines.each do |line|
      next if line.strip.empty?

      expect(source).to include(line.strip)
    end
  end

  it "puts the controller methods on ActionController::Base, not on the declaring module" do
    # The RBS collection declares them on HttpAuthentication::Token::ControllerMethods.
    # Re-declaring there would be a duplicate; on the class it is not, and a
    # class's own method wins over an included module's.
    expect(source).to match(/module ActionController\n  class Base\n/)
    expect(source).to include("def authenticate_or_request_with_http_token")
    expect(source).to include("def authenticate_with_http_token")
  end

  it "rewrites only the def line for the method reached through `extend self`" do
    # `Token.authenticate` is an instance method the module extends onto itself.
    # Declared as the singleton, it wins; the body stays untouched.
    expect(source).to include("def self.authenticate(controller, &login_procedure)")
    expect(source).to include("login_procedure.call(token, options)")

    body = real_body("ActionController::HttpAuthentication::Token", :authenticate, singleton: true)
    expect(body).to start_with("def authenticate(")
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
        method_name: :no_such_method_anywhere,
        singleton: false,
        namespace: ["ActionController", "Base"],
        as_singleton: false
      )]
    )

    expect(described_class.new.build).to be_nil
  end
end
