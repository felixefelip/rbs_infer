# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# A block a method KEEPS is not a block it runs. `included do … end` stores one and
# `base.class_eval(&@included_block)` replays it later, against the includer — so the
# body a caller writes inside that block is written against a `self` the storing method
# never mentions. `Module#class_eval` declares it (`{ (self m) [self: self] -> U }`), and
# without the binding in the signature the stored proc cannot be handed to `class_eval`
# at all: `Ruby::BlockTypeMismatch` (felixefelip/rbs_infer#208).
RSpec.describe "a block stored in an ivar" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # The `included do … end` mechanism in one method: no argument stores the block, an
  # argument replays it. The RBS is the previous pass's — the replay's receiver has to be
  # typed before there is a callee to ask, which is the order the stabilization loop
  # already converges in.
  it "takes its self binding from the call that replays it" do
    target = write("app/hookable.rb", <<~RUBY)
      module Hookable
        def hook(mod = nil, &block)
          if mod.nil?
            @hook_block = block
          else
            mod.class_eval(&@hook_block) if @hook_block
          end

          nil
        end
      end
    RUBY
    write("sig/generated/hookable.rbs", <<~RBS)
      module Hookable
        @hook_block: ^(*untyped) -> untyped?

        def hook: (?Module? mod) ?{ (*untyped) -> untyped } -> nil
      end
    RBS

    rbs = RbsInfer::Analyzer.new(target_class: "Hookable", target_file: target, source_files: [target]).generate_rbs

    expect(rbs).to include("?{ (*untyped) [self: Module] -> untyped }")
  end

  # Store and replay are routinely written in different methods — the ivar is the slot
  # that joins them, not the method.
  it "joins the store and the replay through the ivar, not the method" do
    target = write("app/hookable.rb", <<~RUBY)
      module Hookable
        def hook(&block)
          @hook_block = block
        end

        def replay(mod)
          mod.class_eval(&@hook_block) if @hook_block
        end
      end
    RUBY
    write("sig/generated/hookable.rbs", <<~RBS)
      module Hookable
        @hook_block: ^(*untyped) -> untyped?

        def hook: () ?{ (*untyped) -> untyped } -> untyped
        def replay: (Module mod) -> untyped
      end
    RBS

    rbs = RbsInfer::Analyzer.new(target_class: "Hookable", target_file: target, source_files: [target]).generate_rbs

    expect(rbs).to include("def hook: () ?{ (*untyped) [self: Module] -> untyped }")
  end

  # The binding comes from a callee that declares one. A method that hands the block to
  # something with no `[self:]` in its signature has nothing to say, and says nothing —
  # the arity stays the storing method's `*untyped` either way, because a block may
  # always ignore what it is passed.
  it "adds nothing when the replay's callee binds no self" do
    target = write("app/hookable.rb", <<~RUBY)
      module Hookable
        def hook(items = nil, &block)
          if items.nil?
            @hook_block = block
          else
            items.each(&@hook_block) if @hook_block
          end

          nil
        end
      end
    RUBY

    rbs = RbsInfer::Analyzer.new(target_class: "Hookable", target_file: target, source_files: [target]).generate_rbs

    expect(rbs).not_to include("[self:")
  end
end
