# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::LocalSelfPaths do
  it "reads the locals that are a reader of self, by method" do
    source = <<~RUBY
      class Target
        def label
          _ = user
          _.name
        end

        def other
          u = user
          u = nil if rand > 0.5
          u.name
        end
      end
    RUBY

    expect(described_class.for(source, path: "app/target.rb")).to eq({ ["label", 2] => Set["_"] })
  end

  # Said, not swallowed: a file whose locals cannot be read loses types, and
  # nothing else shows it.
  it "warns about a source the checker's parser refuses, naming the file" do
    expect { expect(described_class.for("def broken(\n", path: "app/broken.rb")).to eq({}) }
      .to output(%r{\[rbs_infer\] could not read the locals of app/broken.rb: Parser::SyntaxError}).to_stderr
  end

  it "lets any other error surface" do
    allow(Steep::Contracts::AliasResolver).to receive(:local_aliases).and_raise(NoMethodError, "a bug")

    expect { described_class.for("class A\n  def x\n    _ = y\n  end\nend\n # unique\n", path: "app/a.rb") }
      .to raise_error(NoMethodError, "a bug")
  end
end
