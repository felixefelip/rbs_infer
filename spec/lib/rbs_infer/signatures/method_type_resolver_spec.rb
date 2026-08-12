require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../../support/temp_file_helpers"

RSpec.describe RbsInfer::Signatures::MethodTypeResolver do
  include TempFileHelpers

  # Test-only builder. `mixin_index:` is REQUIRED in production — it is what says
  # who includes a module, so a call site inside a concern has a `self` to pass,
  # and a caller that forgets it degrades silently (see
  # docs/engineering/required-threaded-deps.md). Here it is built from the same
  # files the resolver gets, which is what the Analyzer does too.
  def build_resolver(source_files, **kwargs)
    described_class.new(
      source_files,
      mixin_index: RbsInfer::Project::MixinIndex.new(source_files),
      invoker_self_types: RbsInfer::Inference::InvokerSelfTypes.new(
        source_index: RbsInfer::Project::SourceIndex.new(source_files),
        parse_cache: RbsInfer::Project::ParseCache.new
      ),
      **kwargs
    )
  end

  it "resolve tipo de método anotado com #:" do
    files = {
      "foo.rb" => <<~RUBY
        class Foo
          #: -> String
          def name
            "hello"
          end
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("Foo", "name")).to eq("String")
    end
  end

  it "resolve attr_reader anotado" do
    files = {
      "foo.rb" => <<~RUBY
        class Foo
          attr_reader :count #: Integer
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("Foo", "count")).to eq("Integer")
    end
  end

  it "resolve keyword defaults do initialize" do
    files = {
      "foo.rb" => <<~RUBY
        class Foo
          attr_accessor :repo

          def initialize(repo: DefaultRepo.new)
            self.repo = repo
          end
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("Foo", "repo")).to eq("DefaultRepo")
    end
  end

  it "resolve attrs via self.attr = Klass.new(...)" do
    files = {
      "my_app/foo.rb" => <<~RUBY
        module MyApp
          class Foo
            attr_reader :widget

            def initialize(name:)
              self.widget = Widget.new(value: name)
            end

            private

            attr_writer :widget
          end
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("MyApp::Foo", "widget")).to eq("Widget")
    end
  end

  it "infere attrs via call-sites quando sem anotação" do
    entity_src = <<~RUBY
      module MyApp
        class Entity
          attr_reader :nome

          def initialize(nome:)
            self.nome = nome
          end

          private

          attr_writer :nome
        end
      end
    RUBY
    service_src = <<~RUBY
      module MyApp
        class Service
          def call
            MyApp::Entity.new(nome: "test")
          end
        end
      end
    RUBY

    with_temp_files("my_app/entity.rb" => entity_src, "my_app/service.rb" => service_src) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("MyApp::Entity", "nome")).to eq("String")
    end
  end

  it "resolve_init_param_types retorna tipos dos parâmetros (não dos attrs)" do
    entity_src = <<~RUBY
      module MyApp
        class Entity
          attr_reader :email

          def initialize(email:)
            self.email = Wrapper.new(value: email)
          end

          private

          attr_writer :email
        end
      end
    RUBY
    caller_src = <<~RUBY
      module MyApp
        class Caller
          def call
            MyApp::Entity.new(email: "test@email.com")
          end
        end
      end
    RUBY

    with_temp_files("my_app/entity.rb" => entity_src, "my_app/caller.rb" => caller_src) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("MyApp::Entity", "email")).to eq("Wrapper")
      expect(resolver.resolve_init_param_types("MyApp::Entity")["email"]).to eq("String")
    end
  end

  # Regression: finders narrowed by the gem_rbs_collection ValidatedModel
  # change return strings like `(OrderImport & OrderImport::Validated)`.
  # `MethodTypeResolver#resolve` used to feed that whole string into
  # `RBS::TypeName` and ended up with a garbage symbol like `:"Validated)"`,
  # so the lookup silently failed and the caller saw `untyped` instead of
  # the real return type.
  it "resolve method on an intersection-type string (right-to-left)" do
    files = {
      "uploader.rb" => <<~RUBY,
        class Uploader
        end
      RUBY
      "model.rb" => <<~RUBY,
        class Model
          #: -> Uploader
          def file
            Uploader.new
          end
        end
      RUBY
      "validated.rb" => <<~RUBY
        class Model::Validated
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("Model & Model::Validated", "file")).to eq("Uploader")
      expect(resolver.resolve("(Model & Model::Validated)", "file")).to eq("Uploader")
    end
  end

  # When the right-most component defines the method (and would win in
  # `intersection_shape`), prefer its declaration. File names follow the
  # Rails convention so `find_class_file` resolves both classes.
  it "prefere o componente da direita em intersection_shape merge order" do
    files = {
      "left_class.rb" => <<~RUBY,
        class LeftClass
          #: -> String
          def shared
            "left"
          end
        end
      RUBY
      "right_class.rb" => <<~RUBY
        class RightClass
          #: -> Symbol
          def shared
            :right
          end
        end
      RUBY
    }

    with_temp_files(files) do |dir, paths|
      resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("(LeftClass & RightClass)", "shared")).to eq("Symbol")
    end
  end

  # felixefelip/rbs_infer#129: a namespaced service called by its bare name from
  # the model that encloses it — `Archiver.new(self).call` inside `class Post`,
  # where the class is `Post::Archiver`.
  describe "#qualify_constant" do
    let(:namespaced_service) do
      {
        "post.rb" => <<~RUBY,
          class Post
            def archive
              Archiver.new(self).call
            end
          end
        RUBY
        "post/archiver.rb" => <<~RUBY
          class Post
            class Archiver
              #: -> String
              def call
                "archived"
              end
            end
          end
        RUBY
      }
    end

    it "resolves a bare constant against the enclosing namespace" do
      with_temp_files(namespaced_service) do |dir, paths|
        resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
        expect(resolver.qualify_constant("Archiver", enclosing: "Post")).to eq("Post::Archiver")
      end
    end

    # The sharp case: a top-level class shares the short name, so the SAME written
    # constant names two different classes depending on where it is written. Without
    # the enclosing scope there is no answer to give — only a coin flip.
    it "gives the same written name two answers, one per enclosing scope" do
      files = namespaced_service.merge(
        "archiver.rb" => <<~RUBY,
          class Archiver
            #: -> Integer
            def call
              0
            end
          end
        RUBY
        "comment.rb" => <<~RUBY
          class Comment
            def archive
              Archiver.new.call
            end
          end
        RUBY
      )

      with_temp_files(files) do |dir, paths|
        resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)

        expect(resolver.qualify_constant("Archiver", enclosing: "Post")).to eq("Post::Archiver")
        expect(resolver.qualify_constant("Archiver", enclosing: "Comment")).to eq("Archiver")

        # Only the qualified name reaches the RBS declaration, which is where a
        # real project's types come from (rbs_rails output, a previous pass's
        # `sig/`). The source fallback is more forgiving — `FileIndex` matches on a
        # path SUFFIX, so even a bare `Archiver` finds `post/archiver.rb` — which is
        # precisely why this miss went unnoticed: it degraded only on the RBS path.
        expect(resolver.resolve("Post::Archiver", "call")).to eq("String")
      end
    end

    it "keeps a constant that is not the enclosing namespace's" do
      with_temp_files(namespaced_service) do |dir, paths|
        resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
        expect(resolver.qualify_constant("Post", enclosing: "Post")).to eq("Post")
      end
    end

    # An unknown constant (stdlib, a gem, something generated at runtime) has to
    # flow through untouched, so the resolvers that CAN see it still get a chance.
    it "returns the written name when no candidate is known" do
      with_temp_files(namespaced_service) do |dir, paths|
        resolver = build_resolver(paths, constant_resolver: fake_constant_resolver)
        expect(resolver.qualify_constant("Time", enclosing: "Post")).to eq("Time")
      end
    end
  end

  # felixefelip/rbs_infer#168. The bulk map (`resolve_all`) is what a call-site
  # collector reads a receiverless call's type from, and it was answering
  # `untyped` where `#resolve` — same resolver, same method — answered from RBS.
  # A reader whose body is just `@ticket` is the shape: nothing structural to
  # infer, everything to read back from the previous pass's `sig/`.
  describe "#resolve_all against an earlier pass's sig/" do
    around do |ex|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
    end
    before { RbsInfer::Signatures::RbsTypeLookup.reset! }

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end

    it "lets the RBS answer through instead of recording untyped over it" do
      source = write("app/models/example.rb", <<~RUBY)
        class Example
          def ticket
            @ticket
          end
        end
      RUBY
      write("sig/example.rbs", <<~RBS)
        class Example
          def ticket: () -> Ticket?
        end
      RBS

      resolver = build_resolver([source], constant_resolver: fake_constant_resolver)

      expect(resolver.resolve_all("Example")).to include("ticket" => "Ticket?")
      # The single-method path already answered this; the two agreeing is the point.
      expect(resolver.resolve("Example", "ticket")).to eq("Ticket?")
    end

    it "keeps a type the source itself states, over the RBS" do
      source = write("app/models/example.rb", <<~RUBY)
        class Example
          #: -> String
          def ticket
            @ticket
          end
        end
      RUBY
      write("sig/example.rbs", "class Example\n  def ticket: () -> Ticket?\nend\n")

      resolver = build_resolver([source], constant_resolver: fake_constant_resolver)

      expect(resolver.resolve_all("Example")).to include("ticket" => "String")
    end
  end

  # A call on a `T?` receiver runs one of TWO bodies, and the nil one is ordinary
  # code whenever NilClass defines the method. Resolving only the base type
  # emitted `Card::Golden#golden?: () -> true` for `goldness.present?` — Rails
  # gives `ActiveRecord::Core#present?` the literal `true`, and the `false` from
  # the nil branch was dropped, so Steep rejected the body it had just typed as
  # `(true | false)`.
  describe "#resolve on a nilable receiver" do
    subject(:resolver) { build_resolver([], constant_resolver: fake_constant_resolver) }

    it "unions the nil branch when NilClass defines the method" do
      # `Object#nil?: () -> false` against `NilClass#nil?: () -> true`.
      expect(resolver.resolve("String", "nil?")).to eq("false")
      expect(resolver.resolve("String?", "nil?")).to eq("bool")
    end

    it "drops the nil branch's literal when the base's class already covers it" do
      # `NilClass#to_s: () -> ""`, and `"" <: String` — the union is `String`.
      expect(resolver.resolve("Integer?", "to_s")).to eq("String")
    end

    it "keeps the optimistic base answer when NilClass does not define it" do
      # The nil branch would be a NoMethodError — the app's steep check flags the
      # unhandled nil; there is no second return type to union in.
      expect(resolver.resolve("String?", "upcase")).to eq("String")
    end

    it "keeps the base answer when a branch's type is receiver-relative" do
      # `self` means a different type in each branch, and the caller resolves a
      # returned `self` against ONE receiver, so the union isn't expressible.
      expect(resolver.resolve("String?", "itself")).to eq("self")
    end
  end
end
