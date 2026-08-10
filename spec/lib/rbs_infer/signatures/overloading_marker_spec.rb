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

    expect(rbs).to include("def include: (*untyped) -> self | ...")
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

    expect(rbs).to include("def include: (*untyped) -> self | ...")
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

    expect(definition.methods[:include].method_types.map(&:to_s).first).to eq("(*untyped) -> self")
  end
end
