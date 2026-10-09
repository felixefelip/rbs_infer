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
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

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

  # `name` is a `String` by the time `super` runs, not the `Symbol` declared.
  # The value passed is unknown, which adds nothing, as for any argument whose
  # type is not known.
  it "does not pass the declared type of a parameter the body reassigns" do
    base_rbs
    write("app/kid.rb", <<~RUBY)
      class Kid < Base
        def initialize(name)
          name = name.to_s
          super
        end
      end
    RUBY
    write("app/caller.rb", "class Caller\n  def run = Base.new(:direct)\nend\n")
    write("sig/generated/base.rbs", <<~RBS)
      class Base
        def initialize: (untyped name) -> void
      end
      class Kid < Base
        def initialize: (Symbol name) -> void
      end
    RBS

    expect(base_initialize).to eq("def initialize: (:direct name) -> void")
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
