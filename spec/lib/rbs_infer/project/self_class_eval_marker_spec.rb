# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::SelfClassEvalMarker do
  let(:source) do
    <<~RUBY
      class Foo
        def build
          self.class.class_eval do
            def age
              25
            end
          end
        end
      end
    RUBY
  end

  it "names the marker after the method that defines the methods" do
    expect(described_class.markers_for(source).map { |m| m[:marker] })
      .to eq(["::Foo::AfterBuild"])
  end

  # The intersection, not the marker alone: the receiver keeps everything it
  # already had and gains what the call put there.
  it "narrows the receiver to the class intersected with its marker" do
    expect(described_class.postconditions_for(source)).to eq(
      [{
        "class" => "Foo",
        "method" => "build",
        "unconditional" => { "self" => "::Foo & ::Foo::AfterBuild" }
      }]
    )
  end

  it "agrees with the RBS the expander emits, which is what makes it apply" do
    marker = described_class.markers_for(source).first.fetch(:marker)
    expanded = RbsInfer::Project::SelfClassEvalExpander.expand(source)

    # A marker the RBS does not declare makes the narrowing silently no-op, so
    # the name in the sidecar has to be the name in the reopening, verbatim.
    expect(expanded).to include("class #{marker.delete_prefix("::")}\n")
  end

  it "says nothing for a file with no relocation" do
    expect(described_class.postconditions_for("class Foo\n  def build; end\nend\n")).to eq([])
  end

  # A method whose name cannot form a constant has no marker to point at. The
  # expander falls back to the class itself, so there is nothing to narrow to
  # and nothing to say here either.
  it "says nothing for a method whose name cannot name a constant" do
    source = <<~RUBY
      class Foo
        def []=(key, value)
          self.class.class_eval { def age; 25; end }
        end
      end
    RUBY

    expect(described_class.postconditions_for(source)).to eq([])
    expect(RbsInfer::Project::SelfClassEvalExpander.expand(source)).to include("class Foo\n")
  end
end
