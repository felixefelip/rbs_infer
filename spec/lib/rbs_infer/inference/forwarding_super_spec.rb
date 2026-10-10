# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Inference::ForwardingSuper do
  describe ".desugar" do
    def desugar(source) = described_class.desugar(source)

    it "writes out each parameter as the bare super passes it" do
      expect(desugar(<<~RUBY)).to include("super(a, b, *rest, c, flag: flag, **opts)")
        def call(a, b = 1, *rest, c, flag:, **opts, &blk)
          super
        end
      RUBY
    end

    it "keeps the block attached to the super" do
      expect(desugar("def call(name)\n  super { |x| x }\nend\n")).to include("super(name) { |x| x }")
    end

    it "leaves a super that already has arguments alone" do
      source = "def call(name)\n  super(name.to_s)\nend\n"
      expect(desugar(source)).to eq(source)
    end

    it "leaves the super bare where a parameter has no name to read" do
      ["def call(*)\n  super\nend\n", "def call(**)\n  super\nend\n", "def call(...)\n  super\nend\n",
       "def call((a, b))\n  super\nend\n"].each do |source|
        expect(desugar(source)).to eq(source)
      end
    end

    it "leaves a super outside any method bare" do
      source = "define_method(:call) { |x| super }\n"
      expect(desugar(source)).to eq(source)
    end
  end

  # Read end to end: a bare `super` in a subclass's `initialize`, as a call
  # site of the `initialize` it reaches (felixefelip/rbs_infer#412).
  describe "a bare super, read as a call site" do
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
  end
end
