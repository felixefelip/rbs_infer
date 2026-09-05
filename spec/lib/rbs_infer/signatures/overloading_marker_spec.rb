# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"

# `# @rbs_infer |...` above a def emits RBS's *overloading* form, putting the signature
# AHEAD of one something else already declares instead of colliding with it. Two plain
# declarations of one method in a class is a `DuplicatedMethodDefinitionError`, and `| ...`
# with nothing to overload is an `InvalidOverloadMethodError` — both poison the whole
# environment rather than degrading, which is why the marker is confirmed and not trusted.
RSpec.describe "the `# @rbs_infer |...` overloading marker" do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  def rbs_for(class_name, source)
    path = File.join(@dir, "probe.rb")
    File.write(path, source)
    RbsInfer::Analyzer.new(target_class: class_name, target_file: path, source_files: [path]).generate_rbs
  end

  it "emits the overloading form for a method the environment already declares" do
    rbs = rbs_for("Module", <<~RUBY)
      class Module
        # @rbs_infer |...
        def include(*mods)
          self
        end
      end
    RUBY

    expect(rbs).to include("def include: (*untyped mods) -> self | ...")
  end

  # A method the class does not declare but an ANCESTOR does. Core puts `extend` on
  # `Kernel`, which `Object` only includes, so a plain `class Object; def extend` is
  # legal RBS — and REPLACES `(*Module) -> self`, taking the fallback with it. Since the
  # generated parameter is a closed union of the call sites we saw, an `extend` naming
  # anything outside it would then have nothing to resolve against
  # (felixefelip/rbs_infer#302).
  it "confirms the marker against a method an ancestor declares" do
    rbs = rbs_for("Object", <<~RUBY)
      class Object
        # @rbs_infer |...
        def extend(*mods)
          self
        end
      end
    RUBY

    expect(rbs).to include("| ...")
  end

  # …and only for an INSTANCE member. `frozen?` is `Kernel`'s, an instance method;
  # a `def self.frozen?` confirmed against it would put `| ...` on the SINGLETON, where
  # there is nothing to overload — `InvalidOverloadMethodError`, which poisons the whole
  # environment rather than degrading. The ancestor chain read above is the instance one,
  # so a singleton member keeps the same-type answer it has always had.
  it "does not confirm a `def self.` against an ancestor's instance method" do
    rbs = rbs_for("Object", <<~RUBY)
      class Object
        # @rbs_infer |...
        def self.frozen?
          true
        end
      end
    RUBY

    expect(rbs).to include("def self.frozen?")
    expect(rbs).not_to include("| ...")
  end

  # The marker states intent; claiming it where there is nothing to overload would be a
  # hard failure, so it degrades to the plain form instead.
  it "ignores the marker when nothing else declares the method" do
    rbs = rbs_for("ZzLoneProbe", <<~RUBY)
      class ZzLoneProbe
        # @rbs_infer |...
        def only_here(x)
          x.to_s
        end
      end
    RUBY

    expect(rbs).to include("def only_here: (untyped x) -> untyped")
    expect(rbs).not_to include("| ...")
  end

  # A `def self.` is rendered by its own branch, and for a while only the instance one
  # honoured the flag: the marked singleton came out PLAIN, which is the duplicate
  # declaration the marker exists to avoid. It fails quietly — RBS raises only when
  # something builds the class — so the collision waits in the environment for a call
  # site to reach it.
  it "emits the overloading form for a `def self.` too" do
    rbs = rbs_for("Process", <<~RUBY)
      module Process
        # @rbs_infer |...
        def self.pid
          0
        end
      end
    RUBY

    expect(rbs).to include("def self.pid: () -> Integer | ...")
  end

  # Confirmed against the member's OWNER. A def in a nested module belongs to
  # `Target::Owner`, and asking under the target's own name finds nothing — dropping the
  # marker and emitting the plain form, i.e. the collision again. `ActiveSupport::Concern`
  # is a nested module in exactly this position.
  it "confirms a nested module's method against that module, not the file's target" do
    rbs = rbs_for("Process", <<~RUBY)
      module Process
        module Sys
          # @rbs_infer |...
          def self.getuid
            0
          end
        end
      end
    RUBY

    expect(rbs).to include("def self.getuid: () -> Integer | ...")
  end

  it "leaves an unmarked method alone even when the environment declares it" do
    rbs = rbs_for("Module", <<~RUBY)
      class Module
        def include(*mods)
          self
        end
      end
    RUBY

    expect(rbs).to include("def include:")
    expect(rbs).not_to include("| ...")
  end

  it "accepts `| ...`, `|...` and a bare `...`" do
    ["# @rbs_infer |...", "# @rbs_infer | ...", "# @rbs_infer ..."].each do |marker|
      rbs = rbs_for("Module", <<~RUBY)
        class Module
          #{marker}
          def include(*mods)
            self
          end
        end
      RUBY

      expect(rbs).to include("| ..."), "esperava a forma overloading para #{marker.inspect}"
    end
  end

  it "marks only the def the comment sits above" do
    rbs = rbs_for("Module", <<~RUBY)
      class Module
        # @rbs_infer |...
        def include(*mods)
          self
        end

        def prepend(*mods)
          self
        end
      end
    RUBY

    expect(rbs).to include("def include: (*untyped mods) -> self | ...")
    expect(rbs).to match(/def prepend: [^|]+$/m)
  end

  # An RBS environment refuses both failure modes outright, so the point of the marker is
  # that the emitted signature actually LOADS beside the one it overloads.
  it "produces RBS the environment accepts beside the core declaration" do
    rbs = rbs_for("Module", <<~RUBY)
      class Module
        # @rbs_infer |...
        def include(*mods)
          self
        end
      end
    RUBY

    sig = File.join(@dir, "probe.rbs")
    File.write(sig, rbs)

    loader = RBS::EnvironmentLoader.new(core_root: RBS::EnvironmentLoader::DEFAULT_CORE_ROOT)
    loader.add(path: Pathname(sig))
    env = RBS::Environment.from_loader(loader).resolve_type_names
    definition = RBS::DefinitionBuilder.new(env: env).build_instance(RBS::TypeName.parse("::Module").absolute!)

    expect(definition.methods[:include].method_types.map(&:to_s).first).to eq("(*untyped mods) -> self")
  end
end
