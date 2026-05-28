require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::ClassNameExtractor do
  def extract_class(source, file_path: nil)
    result = Prism.parse(source)
    visitor = described_class.new(file_path: file_path)
    result.value.accept(visitor)
    visitor.class_name
  end

  def extract(source, file_path: nil)
    result = Prism.parse(source)
    visitor = described_class.new(file_path: file_path)
    result.value.accept(visitor)
    [visitor.class_name, visitor.is_module]
  end

  it "extrai nome de classe simples" do
    expect(extract_class("class Foo; end")).to eq("Foo")
  end

  it "extrai classe dentro de módulos inline" do
    source = <<~RUBY
      module Academico::Aluno
        class Entity
        end
      end
    RUBY
    expect(extract_class(source)).to eq("Academico::Aluno::Entity")
  end

  it "extrai classe com módulos aninhados" do
    source = <<~RUBY
      module Academico
        module Aluno
          class Email
          end
        end
      end
    RUBY
    expect(extract_class(source)).to eq("Academico::Aluno::Email")
  end

  it "não sobrescreve classe-alvo com classe aninhada (nested class inside target)" do
    source = <<~RUBY
      class Webhook::Delivery < ApplicationRecord
        class ResponseTooLarge < StandardError; end

        def deliver; end
      end
    RUBY
    expect(extract_class(source)).to eq("Webhook::Delivery")
  end

  context "quando o file_path é informado" do
    it "seleciona o módulo interno quando a classe externa só o envolve" do
      source = <<~RUBY
        class User
          module Idade
            def idade; end
          end
        end
      RUBY
      expect(extract(source, file_path: "app/models/user/idade.rb"))
        .to eq(["User::Idade", true])
    end

    it "seleciona a classe interna quando a classe externa só a envolve" do
      source = <<~RUBY
        class Caderneta
          class Cadastrar
            def call; end
          end
        end
      RUBY
      expect(extract(source, file_path: "app/models/caderneta/cadastrar.rb"))
        .to eq(["Caderneta::Cadastrar", false])
    end

    it "mantém a classe externa quando o basename corresponde a ela" do
      source = <<~RUBY
        class Webhook::Delivery < ApplicationRecord
          class ResponseTooLarge < StandardError; end
          def deliver; end
        end
      RUBY
      expect(extract_class(source, file_path: "app/models/webhook/delivery.rb"))
        .to eq("Webhook::Delivery")
    end

    it "cai pro fallback quando o basename não corresponde a nenhum candidato" do
      source = <<~RUBY
        module Outer
          class Inner; end
        end
      RUBY
      expect(extract_class(source, file_path: "app/models/desconhecido.rb"))
        .to eq("Outer::Inner")
    end
  end
end
