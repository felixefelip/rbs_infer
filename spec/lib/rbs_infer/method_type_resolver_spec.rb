require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"
require_relative "../../support/temp_file_helpers"

RSpec.describe RbsInfer::Analyzer::MethodTypeResolver do
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
      resolver = described_class.new(paths)
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
      resolver = described_class.new(paths)
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
      resolver = described_class.new(paths)
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
      resolver = described_class.new(paths)
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
      resolver = described_class.new(paths)
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
      resolver = described_class.new(paths)
      expect(resolver.resolve("MyApp::Entity", "email")).to eq("Wrapper")
      expect(resolver.resolve_init_param_types("MyApp::Entity")["email"]).to eq("String")
    end
  end
end
