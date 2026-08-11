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
