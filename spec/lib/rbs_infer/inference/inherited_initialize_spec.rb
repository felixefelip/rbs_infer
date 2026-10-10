# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# An `initialize` is called by every `new` that runs it, not only by the `new`
# of its own class: a subclass without an `initialize` of its own runs the
# inherited one, and a subclass's `super` hands its arguments on to the one
# above (felixefelip/rbs_infer#412). Which `initialize` runs is the RBS
# definition's answer, so the signatures below are the previous pass's output.
RSpec.describe "call sites of an inherited initialize" do
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

  def base_rbs
    write("app/base.rb", <<~RUBY)
      class Base
        def initialize(name)
          @name = name
        end
      end
    RUBY
  end

  def base_initialize
    RbsInfer::Analyzer.new(target_class: "Base", target_file: "app/base.rb", source_files: Dir["app/*.rb"])
                      .generate_rbs[/def initialize: .*/]
  end

  it "reads a subclass's new, in a file that never names the base" do
    base_rbs
    write("app/kid.rb", "class Kid < Base\nend\n")
    write("app/caller.rb", "class Caller\n  def run = Kid.new(:posts)\nend\n")
    write("sig/generated/base.rbs", "class Base\n  def initialize: (untyped name) -> void\nend\nclass Kid < Base\nend\n")

    expect(base_initialize).to eq("def initialize: (:posts name) -> void")
  end

  it "reads a super with arguments, by the position each one takes" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(count, name)
          super(name)
          @count = count
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (Integer count, Symbol name) -> void
      end
    RBS

    expect(base_initialize).to eq("def initialize: (Symbol name) -> void")
  end

  it "reads a bare super as the method's own parameters, as declared" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name)
          super
          @kid = true
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (Symbol name) -> void
      end
    RBS

    expect(base_initialize).to eq("def initialize: (Symbol name) -> void")
  end

  # A bare `super` passes what each parameter holds when it runs, which the
  # checker reads off the call written out: `name` is a `String` by then.
  it "passes what a parameter holds at a bare super, not what it was declared" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name)
          name = name.to_s
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (Symbol name) -> void
      end
    RBS

    expect(base_initialize).to eq("def initialize: (String name) -> void")
  end

  it "passes a parameter narrowed before a bare super as narrowed" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name)
          name ||= :fallback
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (Symbol? name) -> void
      end
    RBS

    expect(base_initialize).to eq("def initialize: (Symbol name) -> void")
  end

  # Inside the block, `name` written out would read the block's parameter;
  # the bare `super` still passes the method's. Left bare, it passes nothing.
  it "leaves a bare super bare where a block parameter shadows the method's" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name)
          [1].each { |name| super }
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (Symbol name) -> void
      end
    RBS

    expect(base_initialize).to start_with("def initialize: (untyped name) ->")
  end

  it "reads a subclass nested in a module" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      module Admin
        class Kid < Base
          def initialize(name)
            super
          end
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      module Admin
        class Kid < Base
          def initialize: (Symbol name) -> void
        end
      end
    RBS

    expect(base_initialize).to eq("def initialize: (Symbol name) -> void")
  end

  # The RBS is the previous pass's: it has not caught up with the `initialize`
  # `Kid`'s source now defines, and answers with `Base`'s.
  it "reads nothing from a subclass whose source defines an initialize its RBS does not" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(count, name)
          @count = count
        end
      end
    RUBY
    write("app/caller.rb", "class Caller\n  def run = [Base.new(:direct), Kid.new(3, :x)]\nend\n")
    write("sig/generated/base.rbs", "class Base\n  def initialize: (untyped name) -> void\nend\nclass Kid < Base\nend\n")

    expect(base_initialize).to eq("def initialize: (:direct name) -> void")
  end

  # Past a rest, which position an argument lands in depends on how many the
  # rest holds.
  it "maps a bare super's parameters by position up to a rest" do
    write("app/base.rb", "class Base\n  def initialize(first, second)\n    @first = first\n  end\nend\n")
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(first, *rest, last)
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped first, untyped second) -> void
      end
      class Kid < Base
        def initialize: (Symbol first, *Integer rest, String last) -> void
      end
    RBS

    expect(base_initialize).to eq("def initialize: (Symbol first, untyped second) -> void")
  end

  # `super` passes `name: name`, and a positional `name` receives the hash.
  it "does not map a keyword onto a positional parameter of the same name" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name:)
          super
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (name: Symbol) -> void
      end
    RBS

    expect(base_initialize).to start_with("def initialize: (untyped name) ->")
  end

  # Both `initialize`s below are some other class's: the singleton's, and the
  # anonymous class's.
  it "reads only a super in an initialize of the class's own body" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name)
          super(name)
        end

        class << self
          def initialize(x)
            super(1)
          end
        end

        def build
          Class.new(Object) do
            def initialize(x)
              super("anonymous")
            end
          end
        end
      end
    RUBY
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (Symbol name) -> void
        def build: () -> untyped
      end
    RBS

    expect(base_initialize).to eq("def initialize: (Symbol name) -> void")
  end

  it "reads nothing from a subclass whose new runs its own initialize" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name)
          @other = name
        end
      end
    RUBY
    write("app/caller.rb", "class Caller\n  def run = [Base.new(:direct), Kid.new(\"kid\")]\nend\n")
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (String name) -> void
      end
    RBS

    expect(base_initialize).to eq("def initialize: (:direct name) -> void")
  end
end
