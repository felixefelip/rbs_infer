require "spec_helper"
require "rbs_infer"

# Unit specs for the `SetterMarkerSynthesizer`. Pinned in isolation so
# the marker-generation rules (matches attr_reader, skips no-narrow
# methods, etc.) are independent of the Steep bridge's per-method
# write detection — that piece is covered by `steep_bridge_spec`.
RSpec.describe RbsInfer::Markers::SetterMarkerSynthesizer do
  Member = RbsInfer::Inference::Member

  def member(kind:, name:)
    Member.new(kind: kind, name: name, signature: "#{name}: untyped", visibility: :public)
  end

  def synthesize(members:, per_method:, declared:)
    described_class.synthesize(
      members: members,
      ivar_write_types_per_method: per_method,
      declared_ivar_types: declared
    )
  end

  it "emits a marker for a setter that narrows an attr_reader ivar" do
    markers = synthesize(
      members: [member(kind: :attr_reader, name: "name")],
      per_method: { "set_default_name" => { "name" => "String" } },
      declared: { "name" => "String?" }
    )

    expect(markers.size).to eq(1)
    expect(markers.first.marker_name).to eq("AfterSetDefaultName")
    expect(markers.first.method_name).to eq("set_default_name")
    expect(markers.first.overrides).to eq({ "name" => "String" })
  end

  it "emits a marker for a setter that narrows to nil (clear-style method)" do
    markers = synthesize(
      members: [member(kind: :attr_accessor, name: "name")],
      per_method: { "clear_name" => { "name" => "nil" } },
      declared: { "name" => "String?" }
    )

    expect(markers.size).to eq(1)
    expect(markers.first.marker_name).to eq("AfterClearName")
    expect(markers.first.overrides).to eq({ "name" => "nil" })
  end

  it "emits multi-ivar overrides when a setter writes more than one ivar" do
    markers = synthesize(
      members: [
        member(kind: :attr_reader, name: "x"),
        member(kind: :attr_reader, name: "y")
      ],
      per_method: { "setup" => { "x" => "Integer", "y" => "String" } },
      declared: { "x" => "Integer?", "y" => "String?" }
    )

    expect(markers.size).to eq(1)
    expect(markers.first.marker_name).to eq("AfterSetup")
    expect(markers.first.overrides).to eq({ "x" => "Integer", "y" => "String" })
  end

  it "skips ivars without a corresponding attr_reader/attr_accessor" do
    # The class has no reader for `internal_state`, so even though it's
    # narrowed, the marker would be unobservable — refining a type
    # that no public API exposes is just noise.
    markers = synthesize(
      members: [],
      per_method: { "compute" => { "internal_state" => "Integer" } },
      declared: { "internal_state" => "Integer?" }
    )

    expect(markers).to be_empty
  end

  it "accepts attr_writer-only ivars as readable (marker still observable via the writer in callers? no — skip)" do
    # `attr_writer :name` does NOT generate a reader. Marker's
    # `attr_reader name: T` override has nothing to refine. Skip.
    markers = synthesize(
      members: [member(kind: :attr_writer, name: "name")],
      per_method: { "set_default_name" => { "name" => "String" } },
      declared: { "name" => "String?" }
    )

    expect(markers).to be_empty
  end

  it "skips ivars whose narrowed type equals the declared type" do
    # Setter writes the same type that was already declared — emitting
    # `attr_reader name: String` would be a no-op (the original
    # `attr_reader name: String` is identical). Avoid clutter.
    markers = synthesize(
      members: [member(kind: :attr_reader, name: "name")],
      per_method: { "set_name" => { "name" => "String" } },
      declared: { "name" => "String" }
    )

    expect(markers).to be_empty
  end

  it "treats parenthesized declared types as equal to the narrowed form" do
    # `(String | Integer)` vs `String | Integer` mean the same thing.
    # The synthesizer's `same_type?` strips outer parens before
    # comparing so a redundant intersection doesn't sneak in.
    markers = synthesize(
      members: [member(kind: :attr_reader, name: "value")],
      per_method: { "set_value" => { "value" => "String | Integer" } },
      declared: { "value" => "(String | Integer)" }
    )

    expect(markers).to be_empty
  end

  it "skips an ivar that's not declared at all (defensive)" do
    # Synthesizer shouldn't crash if Steep observes a write to an ivar
    # the class never declares. Just skip it.
    markers = synthesize(
      members: [member(kind: :attr_reader, name: "name")],
      per_method: { "set_x" => { "x" => "String" } },
      declared: {}
    )

    expect(markers).to be_empty
  end

  it "sorts markers by marker_name for deterministic RBS output" do
    markers = synthesize(
      members: [member(kind: :attr_reader, name: "name")],
      per_method: {
        "z_finalize"    => { "name" => "String" },
        "a_initialize"  => { "name" => "Integer" }
      },
      declared: { "name" => "untyped" }
    )

    expect(markers.map(&:marker_name)).to eq(["AfterAInitialize", "AfterZFinalize"])
  end

  it "skips methods whose marker name would strip to empty" do
    # `:"="` reduces to "" under pascal_case — no usable marker.
    markers = synthesize(
      members: [member(kind: :attr_reader, name: "x")],
      per_method: { "=" => { "x" => "Integer" } },
      declared: { "x" => "untyped" }
    )

    expect(markers).to be_empty
  end

  it "agrees with Steep::Postconditions::MarkerNaming.pascal_case verbatim" do
    # The whole point of MarkerNaming is single-source-of-truth: if
    # rbs_infer drifts from Steep, the postcondition's `unconditional.self`
    # references a class that doesn't exist in RBS. This spec pins
    # the contract.
    require "steep/postconditions/marker_naming"

    markers = synthesize(
      members: [member(kind: :attr_reader, name: "name")],
      per_method: { "mark_as_complete" => { "name" => "String" } },
      declared: { "name" => "String?" }
    )

    short = "After#{Steep::Postconditions::MarkerNaming.pascal_case("mark_as_complete")}"
    expect(markers.first.marker_name).to eq(short)
  end
end
