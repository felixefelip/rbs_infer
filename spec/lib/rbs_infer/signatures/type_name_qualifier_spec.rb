# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Signatures::TypeNameQualifier do
  def qualify(rbs, declared: %w[Hash Array String Comparable Concurrent::Hash Concurrent::Array])
    described_class.apply(rbs, declared: ->(name) { declared.include?(name) })
  end

  it "roots a name a namespace of the declaration would shadow" do
    rbs = qualify(<<~RBS)
      module Concurrent
        module Collection
          class Backend
            @backend: Hash[untyped, untyped]?
            def keys: () -> Array[String]
          end
        end
      end
    RBS

    expect(rbs).to include("@backend: ::Hash[untyped, untyped]?")
    expect(rbs).to include("def keys: () -> ::Array[String]")
  end

  it "leaves a name nothing shadows as written" do
    rbs = "module Concurrent\n  def name: () -> String\n  include Comparable\nend\n"

    expect(qualify(rbs)).to eq(rbs)
  end

  it "leaves a name that already names the namespace's own constant" do
    rbs = "module Concurrent\n  def dup: () -> Concurrent::Hash[untyped, untyped]\nend\n"

    expect(qualify(rbs)).to eq(rbs)
  end

  it "reaches every position a type is written in" do
    rbs = qualify(<<~RBS)
      module Concurrent
        class Map < Hash[untyped, untyped]
          include Array[untyped]
          attr_reader table: Hash[untyped, untyped]
          def each: [T < Hash[untyped, untyped]] (T) { (Array[T]) -> void } -> singleton(Hash) | ...
        end
      end
    RBS

    expect(rbs).to include("class Map < ::Hash[untyped, untyped]")
    expect(rbs).to include("include ::Array[untyped]")
    expect(rbs).to include("attr_reader table: ::Hash[untyped, untyped]")
    expect(rbs).to include("def each: [T < ::Hash[untyped, untyped]] (T) { (::Array[T]) -> void } " \
                           "-> singleton(::Hash) | ...")
  end

  it "reads a superclass from outside the class, as RBS does" do
    rbs = "class Hash\n  class Table < Hash\n  end\nend\n"

    expect(qualify(rbs, declared: %w[Hash Hash::Table])).to eq(rbs)
  end

  it "counts a declaration the signature itself makes" do
    rbs = qualify(<<~RBS, declared: %w[Totaled Storage::Totaled])
      class Account
        module Storage
          module Totaled
          end
          def total: () -> Storage::Totaled
        end
      end
    RBS

    expect(rbs).to include("def total: () -> ::Storage::Totaled")
  end

  it "leaves a string literal alone" do
    rbs = "module Concurrent\n  def name: () -> \"Hash\"\nend\n"

    expect(qualify(rbs)).to eq(rbs)
  end
end
