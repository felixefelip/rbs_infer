require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::ClassNameExtractor do
  def extract_class(source)
    result = Prism.parse(source)
    visitor = described_class.new
    result.value.accept(visitor)
    visitor.class_name
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
end
