# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# A `super` in a subclass's method is a call site of the method it reaches
# (felixefelip/rbs_infer#414): `Kid#call`'s `super` runs `Base#call`, with
# `Kid#call`'s arguments, written out or passed bare. Which method it reaches is
# the RBS definition's answer, so the signatures below are the previous pass's
# output.
RSpec.describe "super as a call site of the method it reaches" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end

  # Every example writes the same paths, and `Corpus.for` reuses a corpus for
  # an equal file list, which would hand over the previous example's parses.
  before do
    RbsInfer::Signatures::RbsTypeLookup.reset!
    RbsInfer::Project::Corpus.reset!
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def base
    write("app/base.rb", <<~RUBY)
      class Base
        def call(name, count)
          name
        end
      end
    RUBY
  end

  def base_call
    RbsInfer::Analyzer.new(target_class: "Base", target_file: "app/base.rb", source_files: Dir["app/*.rb"])
                      .generate_rbs[/def call: .*?(?= ->)/]
  end

  it "reads a bare super and a super with arguments" do
    base
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def call(name, count)
          super
        end
      end

      class Reorder < Base
        def call(count)
          super(:fixed, count)
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Kid < Base
        def call: (:posts name, Integer count) -> untyped
      end
      class Reorder < Base
        def call: (Integer count) -> untyped
      end
    RBS

    expect(base_call).to eq("def call: ((:posts | :fixed) name, Integer count)")
  end

  # `leaf.rb` names `Kid`, not `Base`, and calls nothing with a `.call`.
  it "reads a super in a file that never names the target" do
    base
    write("app/kid.rb", "class Kid < Base\nend\n")
    write("app/leaf.rb", <<~RUBY)
      class Leaf < Kid
        def call(name, count)
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Kid < Base
      end
      class Leaf < Kid
        def call: (Symbol name, Integer count) -> untyped
      end
    RBS

    expect(base_call).to eq("def call: (Symbol name, Integer count)")
  end

  it "reads a super in a method under a modifier" do
    base
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        private def call(name, count)
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Kid < Base
        private def call: (Symbol name, Integer count) -> untyped
      end
    RBS

    expect(base_call).to eq("def call: (Symbol name, Integer count)")
  end

  it "reads nothing from a method that calls no super" do
    base
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def call(name, count)
          name.to_s
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Kid < Base
        def call: (Symbol name, Integer count) -> String
      end
    RBS

    expect(base_call).to eq("def call: (untyped name, untyped count)")
  end

  # `Leaf`'s `super` runs `Mid#call`, which hands nothing on.
  it "reads nothing through an intermediate override" do
    base
    write("app/kid.rb", <<~RUBY)
      class Mid < Base
        def call(name, count)
          name
        end
      end

      class Leaf < Mid
        def call(name, count)
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Mid < Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Leaf < Mid
        def call: (Symbol name, Integer count) -> untyped
      end
    RBS

    expect(base_call).to eq("def call: (untyped name, untyped count)")
  end

  # The RBS has not caught up with the `call` `Mid`'s source now defines, and
  # answers that `Leaf`'s `super` reaches `Base`.
  it "reads nothing through an override the RBS does not declare yet" do
    base
    write("app/kid.rb", <<~RUBY)
      class Mid < Base
        def call(name, count)
          name
        end
      end

      class Leaf < Mid
        def call(name, count)
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Mid < Base
      end
      class Leaf < Mid
        def call: (Symbol name, Integer count) -> untyped
      end
    RBS

    expect(base_call).to eq("def call: (untyped name, untyped count)")
  end

  # `Other::Kid` defines `call`; `Kid`, the class `Leaf` inherits from through
  # `Base`, does not, and nothing stands between `Leaf`'s `super` and `Base`.
  it "does not take another class of the same name for one on the way" do
    base
    write("app/kid.rb", "class Kid < Base\nend\n")
    write("app/other.rb", <<~RUBY)
      module Other
        class Kid
          def call(name, count) = name
        end
      end
    RUBY
    write("app/leaf.rb", <<~RUBY)
      class Leaf < Kid
        def call(name, count)
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Kid < Base
      end
      module Other
        class Kid
          def call: (untyped name, untyped count) -> untyped
        end
      end
      class Leaf < Kid
        def call: (Symbol name, Integer count) -> untyped
      end
    RBS

    expect(base_call).to eq("def call: (Symbol name, Integer count)")
  end

  # A method under any wrapper is the class's own: `memoize def call` is a
  # `super` site, and on the way it is an override.
  it "reads a method under any wrapper, as a super site and as an override" do
    base
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        memoize def call(name, count)
          super
        end
      end

      class Mid < Base
        memoize def call(name, count) = name
      end

      class Leaf < Mid
        def call(name, count)
          super(name.to_s, count)
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      class Kid < Base
        def call: (Symbol name, Integer count) -> untyped
      end
      class Mid < Base
      end
      class Leaf < Mid
        def call: (Symbol name, Integer count) -> untyped
      end
    RBS

    expect(base_call).to eq("def call: (Symbol name, Integer count)")
  end

  # `Mid`'s `attr_writer` defines `name=`, which the previous pass's RBS does
  # not declare yet: `Kid`'s `super` runs it, not `Base#name=`.
  it "takes an attr_writer on the way as an override" do
    write("app/base.rb", "class Base\n  def name=(value)\n    @name = value\n  end\nend\n")
    write("app/kid.rb", <<~RUBY)
      class Mid < Base
        attr_writer :name
      end

      class Kid < Mid
        def name=(value)
          super(value.to_s)
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def name=: (untyped value) -> untyped
      end
      class Mid < Base
      end
      class Kid < Mid
        def name=: (Symbol value) -> untyped
      end
    RBS

    rbs = RbsInfer::Analyzer.new(target_class: "Base", target_file: "app/base.rb", source_files: Dir["app/*.rb"]).generate_rbs
    expect(rbs[/def name=: .*?(?= ->)/]).to eq("def name=: (untyped value)")
  end

  it "reads a super in a class method, written either way" do
    write("app/base.rb", <<~RUBY)
      class Base
        def self.call(name)
          new
        end
      end
    RUBY
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def self.call(name)
          super(name.to_sym)
        end
      end

      class Other < Base
        class << self
          def call(name)
            super(1)
          end
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def self.call: (untyped name) -> Base
      end
      class Kid < Base
        def self.call: (String name) -> Base
      end
      class Other < Base
        def self.call: (String name) -> Base
      end
    RBS

    rbs = RbsInfer::Analyzer.new(target_class: "Base", target_file: "app/base.rb", source_files: Dir["app/*.rb"]).generate_rbs
    expect(rbs[/def self\.call: .*?(?= ->)/]).to eq("def self.call: ((Symbol | 1) name)")
  end

  # What the block passed to `super` returns, as for any call
  # (felixefelip/rbs_infer#155).
  it "reads the block passed to a super" do
    write("app/base.rb", <<~RUBY)
      class Base
        def each_row(&blk)
          yield 1
        end

        def other(x) = x
      end
    RUBY
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def each_row
          super { |row| :row }
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def each_row: () { (Integer) -> untyped } -> untyped
        def other: (untyped x) -> untyped
      end
      class Kid < Base
        def each_row: () -> untyped
      end
    RBS

    rbs = RbsInfer::Analyzer.new(target_class: "Base", target_file: "app/base.rb", source_files: Dir["app/*.rb"]).generate_rbs
    expect(rbs[/def each_row: .*?(?= -> untyped$)/]).to eq("def each_row: () { (1) -> Symbol }")
  end

  # Declined: which method a module's `super` reaches depends on the class it
  # is included in, and the module's own RBS links it to nothing.
  it "reads nothing from a super in a module method" do
    base
    write("app/kid.rb", <<~RUBY)
      module Loud
        def call(name, count)
          super
        end
      end

      class Kid < Base
        include Loud
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def call: (untyped name, untyped count) -> untyped
      end
      module Loud
        def call: (Symbol name, Integer count) -> untyped
      end
      class Kid < Base
        include Loud
      end
    RBS

    expect(base_call).to eq("def call: (untyped name, untyped count)")
  end
end
