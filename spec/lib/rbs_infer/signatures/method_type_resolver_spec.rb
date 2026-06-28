require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../../support/temp_file_helpers"

RSpec.describe RbsInfer::Signatures::MethodTypeResolver do
  include TempFileHelpers

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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
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
      resolver = described_class.new(paths, constant_resolver: fake_constant_resolver)
      expect(resolver.resolve("(LeftClass & RightClass)", "shared")).to eq("Symbol")
    end
  end
end
