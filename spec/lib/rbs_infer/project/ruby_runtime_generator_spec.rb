# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/project/ruby_runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Project::RubyRuntimeGenerator do
  def build_in(dir) = described_class.new(app_dir: dir).build

  it "emits `Module#include`, with the calls it makes inside it" do
    Dir.mktmpdir do |dir|
      files = build_in(dir)

      expect(files.map(&:filename)).to eq(["module.rb"])
      expect(files.first.source).to include(
        "class Module\n",
        "  def include(*modules)\n",
        "    modules.reverse_each do |mod|\n" \
        "      mod.send(:append_features, self)\n" \
        "      mod.send(:included, self)\n" \
        "    end\n",
        "    self\n  end\n"
      )
    end
  end

  # The two `include` delegates to, so the file models the whole dispatch rather than its
  # first step, and an app's override has a `super` that resolves.
  describe "the methods `include` calls" do
    it "emits both, under `private`" do
      Dir.mktmpdir do |dir|
        source = build_in(dir).first.source

        expect(source).to include("  private\n")
        expect(source).to include("  def append_features(mod)\n")
        expect(source).to include("  def included(base)\n")
        # Both come from `Module`, both private — measured, not assumed:
        # `Module.instance_method(:included).owner` is `Module`, and RBS core declares
        # `private def included: (Module othermod) -> void`.
        expect(source.index("  private\n")).to be < source.index("  def append_features(mod)\n")
      end
    end

    # `rb_mod_append_features` type-checks its argument before splicing.
    it "keeps append_features' type check" do
      Dir.mktmpdir do |dir|
        expect(build_in(dir).first.source).to include("raise TypeError")
      end
    end

    # `rb_obj_dummy1`: one argument, returns nil. Writing anything else would describe a
    # hook Ruby does not have.
    it "leaves included the no-op it is on Module" do
      Dir.mktmpdir do |dir|
        expect(build_in(dir).first.source).to match(/def included\(base\)\n\s+nil\n\s+end/)
      end
    end

    # A plain `def` would redeclare core's, which RBS rejects with
    # `DuplicatedMethodDefinitionError` — and that aborts the whole run, not just this file.
    it "marks both as overloading" do
      Dir.mktmpdir do |dir|
        source = build_in(dir).first.source

        expect(source).to match(/# @rbs_infer \|\.\.\.\n\s+def append_features\(/)
        expect(source).to match(/# @rbs_infer \|\.\.\.\n\s+def included\(/)
      end
    end
  end

  # `rb_mod_include` is `while (argc--)`, and the direction is observable: `include A, B`
  # runs B's hook first and leaves A closest in the ancestors. `each` would describe a
  # different method.
  it "walks the arguments backwards, as the C does" do
    Dir.mktmpdir do |dir|
      source = build_in(dir).first.source

      expect(source).to include("reverse_each")
      expect(source).not_to include("modules.each")
    end
  end

  # `rb_funcall` dispatches by name ignoring visibility, and `append_features`/`included`
  # are both PRIVATE on Module (`included` a no-op, `rb_obj_dummy1`). The plain-call
  # spelling asserts a public call Ruby never makes — and Steep says so, once the
  # parameter is typed at all: `does not have method 'included'`.
  it "dispatches the private hooks the way rb_funcall does" do
    Dir.mktmpdir do |dir|
      source = build_in(dir).first.source

      expect(source).to include("mod.send(:included, self)")
      expect(source).not_to include("mod.included(self)")
    end
  end

  # `append_features` is where the ancestor chain is actually spliced
  # (`rb_include_module`); a body that only fires the hook has left out what `include`
  # is for.
  it "splices the chain through append_features" do
    Dir.mktmpdir do |dir|
      expect(build_in(dir).first.source).to include("mod.send(:append_features, self)")
    end
  end

  # `rb_check_arity(argc, 1, UNLIMITED_ARGUMENTS)`.
  it "requires at least one module, as the arity check does" do
    Dir.mktmpdir do |dir|
      expect(build_in(dir).first.source).to include("raise ArgumentError")
    end
  end

  # A plain `def include` redeclares core's `Module#include`, which RBS rejects with
  # `DuplicatedMethodDefinitionError` — and that aborts the whole run, not just this file.
  # The marker (#200) makes the emitted signature RBS's overloading form instead.
  it "marks the def as overloading so it adds to core's signature" do
    Dir.mktmpdir do |dir|
      expect(build_in(dir).first.source).to match(/# @rbs_infer \|\.\.\.\n\s+def include\(/)
    end
  end

  describe "#generate" do
    it "writes the sidecar" do
      Dir.mktmpdir do |dir|
        sidecar = described_class.new(app_dir: dir).generate

        expect(File.read(File.join(sidecar, "module.rb"))).to include("mod.send(:included, self)")
      end
    end

    it "rewrites a stale sidecar" do
      Dir.mktmpdir do |dir|
        sidecar = File.join(dir, described_class::SIDECAR_DIR)
        FileUtils.mkdir_p(sidecar)
        File.write(File.join(sidecar, "included_hook.rb"), "::Gone.included(::Gone)\n")

        described_class.new(app_dir: dir).generate

        expect(Dir.children(sidecar)).to eq(["module.rb"])
      end
    end
  end
end
