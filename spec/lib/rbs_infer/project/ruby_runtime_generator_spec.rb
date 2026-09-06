# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/project/ruby_runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Project::RubyRuntimeGenerator do
  def build_in(dir) = described_class.new(app_dir: dir).build

  def source_of(dir, filename) = build_in(dir).find { |f| f.filename == filename }.source

  it "emits `Module#include`, with the calls it makes inside it" do
    Dir.mktmpdir do |dir|
      files = build_in(dir)

      expect(files.map(&:filename)).to eq(["module.rb", "object.rb"])
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

  # The pair `extend` reaches, and they are on `Module` for the same reason the
  # `include` pair is — measured: `Module.instance_method(:extended).owner` is
  # `Module`, and both are private there.
  describe "the methods `extend` calls" do
    it "emits both, under the same `private`" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "module.rb")

        expect(source).to include("  def extend_object(obj)\n", "  def extended(base)\n")
        expect(source.index("  private\n")).to be < source.index("  def extend_object(obj)\n")
      end
    end

    # `rb_mod_extend_object` returns the OBJECT; `rb_mod_append_features` returns the
    # MODULE. Writing the same answer in both would erase the one difference the two
    # splices have that is expressible here.
    it "answers with the object, where append_features answers with the module" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "module.rb")

        expect(source).to match(/def extend_object\(obj\).*\n    obj\n  end/m)
      end
    end

    it "splices into the singleton in Ruby, so `extend` is `include` on another table" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "module.rb")

        expect(source).to include("    obj.singleton_class.include(self)\n")
        expect(source.scan(/^\s+mod\.include\(self\)$/)).to be_empty
      end
    end

    # `rb_obj_dummy1` again: one argument, returns nil.
    it "leaves extended the no-op it is on Module" do
      Dir.mktmpdir do |dir|
        expect(source_of(dir, "module.rb")).to match(/def extended\(base\)\n\s+nil\n\s+end/)
      end
    end

    it "marks both as overloading" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "module.rb")

        expect(source).to match(/# @rbs_infer \|\.\.\.\n\s+def extend_object\(/)
        expect(source).to match(/# @rbs_infer \|\.\.\.\n\s+def extended\(/)
      end
    end
  end

  describe "the methods `prepend` calls" do
    it "emits the pair, under the same `private`" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "module.rb")

        expect(source).to include("  def prepend_features(mod)\n", "  def prepended(base)\n")
        expect(source.index("  private\n")).to be < source.index("  def prepend_features(mod)\n")
      end
    end

    it "reaches the same splice `append_features` reaches" do
      Dir.mktmpdir do |dir|
        expect(source_of(dir, "module.rb"))
          .to match(/def prepend_features\(mod\)\n.*\n\n    mod\.send\(:__rbs_infer__include_module, self\)/)
      end
    end

    it "walks the arguments backwards, through send, as `include` does" do
      Dir.mktmpdir do |dir|
        expect(source_of(dir, "module.rb")).to include(
          "    modules.reverse_each do |mod|\n" \
          "      mod.send(:prepend_features, self)\n" \
          "      mod.send(:prepended, self)\n" \
          "    end\n"
        )
      end
    end

    it "marks all three as overloading" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "module.rb")

        expect(source).to match(/# @rbs_infer \|\.\.\.\n\s+def prepend\(/)
        expect(source).to match(/# @rbs_infer \|\.\.\.\n\s+def prepend_features\(/)
        expect(source).to match(/# @rbs_infer \|\.\.\.\n\s+def prepended\(/)
      end
    end
  end

  # `rb_obj_extend` in object.c, and the file it lands in is the decision this makes.
  describe "`extend`, in object.rb" do
    # `extend` is `Kernel#extend` (measured: `Object.instance_method(:extend).owner`).
    # It is written on `Object` because what reads this file walks the SUPERCLASS chain,
    # which no module is on — a `module Kernel` reopening would be a provider nothing
    # can reach.
    it "reopens Object rather than Kernel" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "object.rb")

        expect(source).to include("class Object\n")
        expect(source).not_to include("module Kernel")
      end
    end

    # `while (argc--)` again, and the two calls it makes are what this whole file is
    # for: `extend Deferring` is the only thing that says `Deferring.extended(self)` ran.
    it "runs extend_object then extended, backwards, through send" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "object.rb")

        expect(source).to include(
          "    modules.reverse_each do |mod|\n" \
          "      mod.send(:extend_object, self)\n" \
          "      mod.send(:extended, self)\n" \
          "    end\n"
        )
        expect(source).not_to include("mod.extended(self)")
      end
    end

    # `for (i = 0; i < argc; i++) Check_Type(argv[i], T_MODULE)` runs over EVERY argument
    # before the hook loop starts. `include` has no such pass — its check lives inside
    # `append_features`, so `include Foo, 1` can already have notified `Foo`. Writing the
    # check inside the backwards loop would describe `include`, not `extend`.
    it "type-checks every argument before any hook runs" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "object.rb")

        expect(source).to include("raise TypeError")
        expect(source.index("modules.each")).to be < source.index("modules.reverse_each")
      end
    end

    # `rb_check_arity(argc, 1, UNLIMITED_ARGUMENTS)`, and `return obj` — `extend` answers
    # with the receiver, which is what makes `obj.extend(M).foo` resolve.
    it "requires an argument and answers with the receiver" do
      Dir.mktmpdir do |dir|
        source = source_of(dir, "object.rb")

        expect(source).to include("raise ArgumentError")
        expect(source).to match(/    self\n  end\nend\n\z/)
      end
    end

    # Core declares `extend` on `Kernel`, and `Object` includes it — so a plain `def`
    # here would REPLACE that declaration for every object in the program rather than
    # add to it. The marker (#200) is what makes it an overload.
    it "marks the def as overloading" do
      Dir.mktmpdir do |dir|
        expect(source_of(dir, "object.rb")).to match(/# @rbs_infer \|\.\.\.\n\s+def extend\(/)
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

        expect(Dir.children(sidecar).sort).to eq(["module.rb", "object.rb"])
      end
    end
  end
end
