# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# A receiver reaches a module's methods two ways, and only one of them was readable.
# `include` puts them on the instances, and `ancestry_match?` (felixefelip/rbs_infer#131)
# already asked RBS who owns a method on an instance type. `extend` puts them on the
# module OBJECT, whose type is `singleton(Host)` — a spelling the owner lookup digested
# into a name no declaration answers to, so every such call site was dropped and the
# module's parameters stayed `untyped` (felixefelip/rbs_infer#208).
#
# The call site that made it matter is the `Module#include` pseudo-code's
# `mod.send(:included, self)`: `mod` is typed as the includers' singletons, and a
# hand-rolled `included` hook sits on one of them only by `extend`.
RSpec.describe "a call site reaching the target through extend" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # The RBS is the previous pass's output — the state the stabilization loop reaches after
  # one round, and the only place the `extend` is written down in a form the ancestor
  # graph can walk.
  def write_signatures
    write("sig/generated/mixin.rbs", "module Mixin\n  def notify: (untyped target) -> untyped\nend\n")
    write("sig/generated/host.rbs", "class Host\n  extend Mixin\nend\n")
  end

  it "types the parameter from a receiver typed as the extending class's singleton" do
    target = write("app/mixin.rb", <<~RUBY)
      module Mixin
        def notify(target)
          target
        end
      end
    RUBY
    write("app/host.rb", "class Host\n  extend Mixin\nend\n")
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          klass = Host
          klass.notify("hi")
        end
      end
    RUBY
    write_signatures

    rbs = RbsInfer::Analyzer.new(target_class: "Mixin", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    expect(rbs).to include("def notify: (String target) ->")
  end

  # The same reach, one level in: the module is NESTED under the target, so it is not a
  # target of its own (felixefelip/rbs_infer#22) and the ancestry lands on a name the
  # enclosing target does not answer to. Compared against the target alone — which is all
  # this matcher used to do — the call site was dropped and the parameter stayed `untyped`
  # (felixefelip/rbs_infer#229).
  it "types a nested module's method reached by extend from a sibling" do
    target = write("app/wrap.rb", <<~RUBY)
      class Wrap
        module Mixin
          def notify(value)
            value
          end
        end

        module Host
          extend Wrap::Mixin
        end
      end
    RUBY
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          klass = Wrap::Host
          klass.notify("hi")
        end
      end
    RUBY
    write("sig/generated/wrap.rbs", <<~RBS)
      class Wrap
        module Mixin
          def notify: (untyped value) -> untyped
        end

        module Host
          extend ::Wrap::Mixin
        end
      end
    RBS

    rbs = RbsInfer::Analyzer.new(target_class: "Wrap", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    expect(rbs).to include("def notify: (String value) ->")
  end

  # And a `def self.` of the same name on the extender SHADOWS it, so the call site
  # belongs to that one and the module's own stays untouched.
  it "leaves the module alone when the extender shadows the method" do
    target = write("app/wrap.rb", <<~RUBY)
      class Wrap
        module Mixin
          def notify(value)
            value
          end
        end

        module Host
          extend Wrap::Mixin

          def self.notify(value)
            value
          end
        end
      end
    RUBY
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          klass = Wrap::Host
          klass.notify("hi")
        end
      end
    RUBY
    write("sig/generated/wrap.rbs", <<~RBS)
      class Wrap
        module Mixin
          def notify: (untyped value) -> untyped
        end

        module Host
          extend ::Wrap::Mixin

          def self.notify: (untyped value) -> untyped
        end
      end
    RBS

    rbs = RbsInfer::Analyzer.new(target_class: "Wrap", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    expect(rbs).to include("def self.notify: (String value) ->")
    expect(rbs).to include("def notify: (untyped value) ->")
  end

  # The same reach again, written the way source actually writes it: the CONSTANT is the
  # receiver. `klass = Host` above gets Steep's `singleton(Host)` out of the local, which
  # says which side is being called; a constant receiver resolves to the bare `"Host"`,
  # which says nothing — `resolve_receiver_type` returns that same string for a value of
  # type `Host`. `owner_match_key` keeps both kinds eligible for such a spelling, but this
  # matcher asked RBS for the owner on the INSTANCE side alone, where an `extend`ed method
  # is not, so the call site was dropped (felixefelip/rbs_infer#293).
  #
  # This is the shape every `ActiveSupport::Concern` has: `class_methods do` becomes a
  # `ClassMethods` module the host extends, and it is called as `Host.the_method(arg)`.
  it "types the parameter from a call written on the extending class's constant" do
    target = write("app/mixin.rb", <<~RUBY)
      module Mixin
        def notify(target)
          target
        end
      end
    RUBY
    write("app/host.rb", "class Host\n  extend Mixin\nend\n")
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          Host.notify("hi")
        end
      end
    RUBY
    write_signatures

    rbs = RbsInfer::Analyzer.new(target_class: "Mixin", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    expect(rbs).to include("def notify: (String target) ->")
  end

  # And the constant spelling earns no more than the typed one does: the singleton side is
  # asked only because the instance side had no such method, and it answers off the same
  # ancestry. A class that does not extend the target still says nothing.
  it "leaves the parameter untyped when the constant's singleton does not reach the target" do
    target = write("app/mixin.rb", <<~RUBY)
      module Mixin
        def notify(target)
          target
        end
      end
    RUBY
    write("app/host.rb", "class Host\nend\n")
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          Host.notify("hi")
        end
      end
    RUBY
    write("sig/generated/mixin.rbs", "module Mixin\n  def notify: (untyped target) -> untyped\nend\n")
    write("sig/generated/host.rbs", "class Host\nend\n")

    rbs = RbsInfer::Analyzer.new(target_class: "Mixin", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    expect(rbs).to include("def notify: (untyped target) ->")
  end

  # The receiver's type is what decides, not the method's name: `singleton(Host)` reaches
  # `Mixin` only because `Host` extends it. A class that does not gives nothing away.
  it "leaves the parameter untyped when the receiver's singleton does not reach the target" do
    target = write("app/mixin.rb", <<~RUBY)
      module Mixin
        def notify(target)
          target
        end
      end
    RUBY
    write("app/host.rb", "class Host\nend\n")
    write("app/caller.rb", <<~RUBY)
      class Caller
        def run
          klass = Host
          klass.notify("hi")
        end
      end
    RUBY
    write("sig/generated/mixin.rbs", "module Mixin\n  def notify: (untyped target) -> untyped\nend\n")
    write("sig/generated/host.rbs", "class Host\nend\n")

    rbs = RbsInfer::Analyzer.new(target_class: "Mixin", target_file: target, source_files: Dir["app/*.rb"]).generate_rbs

    expect(rbs).to include("def notify: (untyped target) ->")
  end
end
