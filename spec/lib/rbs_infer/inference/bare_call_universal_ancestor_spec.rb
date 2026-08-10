# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"

# `include Foo` is `Module#include` on the class object — a call site that names no
# receiver and no target, so all three caller indexes miss it: `files_calling` keys on the
# `.`, `files_referencing` on the constant, and the mixin graph only ever hears about a
# module some source includes. A reopen of `Module` was therefore left with `(*untyped)`
# however many `include`s the project writes.
#
# What makes those files findable is the ancestor graph: `Module` sits behind every class
# object (`singleton(::Host)` → `::Class` → `::Module`), so a bare call to one of its
# methods can be anywhere, and the sweep for that shape is worth paying. `Comparable` is
# the argument here because it is in the core RBS the analyzer loads — the type of a
# constant argument comes from the environment, so a module defined only in the temp
# sources would resolve to nothing and prove nothing.
RSpec.describe "a receiverless call to a universal ancestor's method" do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  def rbs_for(target, files)
    paths = files.map do |name, content|
      File.join(@dir, name).tap { |path| File.write(path, content) }
    end
    target_path = paths.find { |path| File.basename(path) == target }

    RbsInfer::Analyzer.new(target_file: target_path, source_files: paths).generate_rbs
  end

  it "types `Module#include`'s parameter from the `include`s in the project" do
    rbs = rbs_for(
      "module_reopen.rb",
      "module_reopen.rb" => <<~RUBY,
        class Module
          # @rbs_infer |...
          def include(*modules)
            modules
          end
        end
      RUBY
      "host.rb" => "class Host\n  include Comparable\nend\n"
    )

    expect(rbs).to include("def include: (*singleton(::Comparable) modules)")
  end

  # One signature over every call site, so the parameter is the union of everything the
  # project includes — honest for a single body, and the reason a per-includer fact needs
  # something else entirely.
  it "unions what every file includes" do
    rbs = rbs_for(
      "module_reopen.rb",
      "module_reopen.rb" => <<~RUBY,
        class Module
          # @rbs_infer |...
          def include(*modules)
            modules
          end
        end
      RUBY
      "host.rb" => "class Host\n  include Comparable\nend\n",
      "other.rb" => "class Other\n  include Enumerable\nend\n"
    )

    expect(rbs).to match(/def include: \(\*\(singleton\(::(Comparable|Enumerable)\) \| singleton\(::(Comparable|Enumerable)\)\) modules\)/)
  end

  # The sweep is only worth its cost for a target the graph puts behind everything; an
  # ordinary class keeps being found by the constant and call indexes alone.
  it "does not sweep for an ordinary target" do
    rbs = rbs_for(
      "plain.rb",
      "plain.rb" => "class Plain\n  def register(*mods)\n    mods\n  end\nend\n",
      "host.rb" => "class Host\n  register Comparable\nend\n"
    )

    expect(rbs).to include("def register: (*untyped mods)")
  end
end
