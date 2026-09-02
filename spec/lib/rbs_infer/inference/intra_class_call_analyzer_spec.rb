require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::IntraClassCallAnalyzer do
  def analyze(source, attr_types: {}, method_type_resolver: nil)
    result = Prism.parse(source)
    visitor = described_class.new(attr_types: attr_types, method_type_resolver: method_type_resolver)
    result.value.accept(visitor)
    visitor
  end

  # felixefelip/rbs_infer#142. The argument is narrowed at the point it is
  # passed, and the callee's parameter must not be typed as if it were not:
  # a nilable parameter makes every downstream fact about it unprovable.
  it "uses the local's NARROWED type at the call site, not the assignment's", :dummy_app do
    source = <<~RUBY
      class Foo
        def call
          if user = User.where(active: true).first
            publish(user)
          end
        end

        def publish(user)
        end
      end
    RUBY

    bridge = RbsInfer::Signatures::SteepBridge.new
    result = Prism.parse(source)
    visitor = described_class.new(
      steep_bridge: bridge,
      source_code: source,
      method_positional_params: { "publish" => ["user"] }
    )
    result.value.accept(visitor)

    expect(visitor.inferred_param_types["publish"]["user"]).to eq("(User & User::Validated)")
  end

  # felixefelip/rbs_infer#298. A receiverless call resolved through `@attr_types`
  # alone, which only ever holds the class's own `attr_*`. An association reader
  # — or any other `def` — was not in it, came back `untyped`, and the call site
  # was dropped from the candidates. With one other call site typed, the
  # parameter then took THAT site's type as if it were the only one: the union
  # was not widened, it was never formed.
  it "uses the checker's type for an argument that is a self-send", :dummy_app do
    source = <<~RUBY
      class Post
        def call
          publish(user)
        end

        def publish(user)
        end
      end
    RUBY

    bridge = RbsInfer::Signatures::SteepBridge.new
    result = Prism.parse(source)
    visitor = described_class.new(
      steep_bridge: bridge,
      source_code: source,
      method_positional_params: { "publish" => ["user"] }
    )
    result.value.accept(visitor)

    expect(visitor.inferred_param_types["publish"]["user"]).to eq("User?")
  end

  it "infers a kwarg's type through a local assigned from Klass.new(...)" do
    source = <<~RUBY
      class Foo
        def call
          student = Entity.new(name: "test")
          enroll(student:)
        end

        def enroll(student:)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["enroll"]["student"]).to eq("Entity")
  end

  it "unions kwarg types from distinct call-sites (felixefelip/rbs_infer#64)" do
    source = <<~RUBY
      class Foo
        def track_event(action:)
        end

        def track_created
          track_event(action: "created")
        end

        def track_updated
          track_event(action: :updated)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["track_event"]["action"]).to eq("(String | Symbol)")
  end

  it "infers a type through an ImplicitNode (shorthand keyword: enroll(student:))" do
    source = <<~RUBY
      class Foo
        def call
          student = ::MyApp::Entity.new(name: "test")
          enroll(student:)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["enroll"]["student"]).to eq("::MyApp::Entity")
  end

  it "ignores arguments whose type is unknown" do
    source = <<~RUBY
      class Foo
        def call
          enroll(student: something_or_other)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["enroll"]).to be_empty
  end

  it "infers several kwargs from the same call" do
    source = <<~RUBY
      class Foo
        def call
          student = Entity.new
          course = Course.new
          enroll(student:, course:)
        end
      end
    RUBY

    visitor = analyze(source)
    expect(visitor.inferred_param_types["enroll"]["student"]).to eq("Entity")
    expect(visitor.inferred_param_types["enroll"]["course"]).to eq("Course")
  end

  context "usage-side: infers param types from a Klass.new(param:) in the body" do
    let(:resolver) do
      instance_double(RbsInfer::Signatures::MethodTypeResolver).tap do |r|
        allow(r).to receive(:resolve_all).with("Phone").and_return({
          "area_code" => "String",
          "number" => "String"
        })
      end
    end

    it "infers a param's type when it is forwarded by shorthand to Klass.new(param:)" do
      source = <<~RUBY
        class Foo
          def add_phone(area_code:, number:)
            Phone.new(area_code:, number:)
          end
        end
      RUBY

      visitor = analyze(source, method_type_resolver: resolver)
      expect(visitor.inferred_param_types["add_phone"]["area_code"]).to eq("String")
      expect(visitor.inferred_param_types["add_phone"]["number"]).to eq("String")
    end

    it "infers a type through an explicit `param: param` in Klass.new" do
      source = <<~RUBY
        class Foo
          def add(code:)
            Phone.new(area_code: code)
          end
        end
      RUBY

      resolver_local = instance_double(RbsInfer::Signatures::MethodTypeResolver)
      allow(resolver_local).to receive(:resolve_all).with("Phone").and_return({
        "area_code" => "String",
        "number" => "String"
      })

      visitor = analyze(source, method_type_resolver: resolver_local)
      expect(visitor.inferred_param_types["add"]["code"]).to eq("String")
    end

    it "does not infer when the value is not a parameter of the method" do
      source = <<~RUBY
        class Foo
          def add(area_code:)
            local = "11"
            Phone.new(area_code:, number: local)
          end
        end
      RUBY

      visitor = analyze(source, method_type_resolver: resolver)
      expect(visitor.inferred_param_types["add"]["area_code"]).to eq("String")
      expect(visitor.inferred_param_types["add"]).not_to have_key("number")
    end

    it "does not infer without a method_type_resolver" do
      source = <<~RUBY
        class Foo
          def add(area_code:)
            Phone.new(area_code:)
          end
        end
      RUBY

      visitor = analyze(source)
      expect(visitor.inferred_param_types["add"]).to be_empty
    end
  end
end
