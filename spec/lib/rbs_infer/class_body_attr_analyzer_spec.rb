require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::ClassBodyAttrAnalyzer do
  def analyze(source, attr_names)
    result = Prism.parse(source)
    visitor = described_class.new(attr_names: attr_names.to_set)
    result.value.accept(visitor)
    visitor
  end

  it "detecta self.attr = Klass.new() em qualquer método" do
    source = <<~RUBY
      class Foo
        attr_accessor :widget

        def setup
          self.widget = Widget.new(name: "test")
        end
      end
    RUBY

    visitor = analyze(source, ["widget"])
    expect(visitor.attr_types["widget"]).to eq("Widget")
  end

  it "detecta variável local com mesmo nome de attr" do
    source = <<~RUBY
      class Foo
        attr_accessor :result

        def compute
          result = Something.new
        end
      end
    RUBY

    visitor = analyze(source, ["result"])
    expect(visitor.attr_types["result"]).to eq("Something")
  end

  it "detecta attr << Klass.new(...) como elemento da coleção" do
    source = <<~RUBY
      class Entity
        attr_reader :telefones

        def adicionar_telefone(ddd:, numero:)
          telefones << Telefone.new(ddd:, numero:)
        end
      end
    RUBY

    visitor = analyze(source, ["telefones"])
    expect(visitor.collection_element_types["telefones"]).to contain_exactly("Telefone")
  end

  it "detecta self.attr << Klass.new(...) como elemento da coleção" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def add_item(name:)
          self.items << Item.new(name:)
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types["items"]).to contain_exactly("Item")
  end

  it "coleta múltiplos tipos de elementos via << em métodos diferentes" do
    source = <<~RUBY
      class Log
        attr_reader :entries

        def add_error(msg:)
          entries << ErrorEntry.new(msg:)
        end

        def add_info(msg:)
          entries << InfoEntry.new(msg:)
        end
      end
    RUBY

    visitor = analyze(source, ["entries"])
    expect(visitor.collection_element_types["entries"]).to contain_exactly("ErrorEntry", "InfoEntry")
  end

  it "ignora << quando o receiver não é um attr conhecido" do
    source = <<~RUBY
      class Foo
        attr_reader :items

        def process
          other_list << Item.new
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types).to be_empty
  end

  it "detecta push com um elemento" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def add(name:)
          items.push(Item.new(name:))
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types["items"]).to contain_exactly("Item")
  end

  it "detecta push com múltiplos elementos" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def add_defaults
          items.push(Item.new, Widget.new)
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types["items"]).to contain_exactly("Item", "Widget")
  end

  it "detecta append como alias de push" do
    source = <<~RUBY
      class Entity
        attr_reader :tags

        def add_tag(name:)
          tags.append(Tag.new(name:))
        end
      end
    RUBY

    visitor = analyze(source, ["tags"])
    expect(visitor.collection_element_types["tags"]).to contain_exactly("Tag")
  end

  it "detecta unshift" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def prepend_item(name:)
          items.unshift(Item.new(name:))
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types["items"]).to contain_exactly("Item")
  end

  it "detecta prepend como alias de unshift" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def add_first(name:)
          items.prepend(Item.new(name:))
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types["items"]).to contain_exactly("Item")
  end

  it "detecta insert ignorando o primeiro arg (índice)" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def insert_at(pos:, name:)
          items.insert(pos, Item.new(name:))
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types["items"]).to contain_exactly("Item")
  end

  it "detecta concat com array literal" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def add_batch
          items.concat([Item.new, Widget.new])
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types["items"]).to contain_exactly("Item", "Widget")
  end

  it "ignora concat com argumento não-array (variável)" do
    source = <<~RUBY
      class Entity
        attr_reader :items

        def merge(other)
          items.concat(other)
        end
      end
    RUBY

    visitor = analyze(source, ["items"])
    expect(visitor.collection_element_types).to be_empty
  end
end
