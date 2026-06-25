require "spec_helper"
require "rbs_infer"
require "steep"

# Unit specs for the predicate-marker synthesizer. The input here is
# `Steep::Postconditions::InferredEntry` instances (hand-built, no
# live type-checker) so the rules are tested in isolation from
# Steep's source-walking machinery — that machinery is covered by
# Steep's own `PostconditionsInferrerTest`.
RSpec.describe RbsInfer::Markers::PredicateMarkerSynthesizer do
  Member = RbsInfer::Inference::Member
  InferredEntry = Steep::Postconditions::InferredEntry

  def member(kind:, name:)
    Member.new(kind: kind, name: name, signature: "#{name}: untyped", visibility: :public)
  end

  def entry(class_name:, method_name:, when_true_ivars: {}, when_true_self_type_string: nil, ivars: {}, self_type_string: nil, singleton: false)
    InferredEntry.new(
      class_name: class_name,
      method_name: method_name,
      singleton: singleton,
      ivars: ivars,
      self_type_string: self_type_string,
      when_true_ivars: when_true_ivars,
      when_true_self_type_string: when_true_self_type_string
    )
  end

  def string_type
    Steep::AST::Types::Name::Instance.new(name: RBS::TypeName.parse("::String"), args: [])
  end

  it "emits a marker for a predicate whose when_true narrows an attr_reader ivar" do
    markers = described_class.synthesize(
      inferred_entries: [
        entry(
          class_name: "Venue",
          method_name: :confirmed?,
          when_true_ivars: { :"@name" => string_type },
          when_true_self_type_string: "::Venue & ::Venue::AfterConfirmed"
        )
      ],
      target_class: "Venue",
      members: [member(kind: :attr_accessor, name: "name")]
    )

    expect(markers.size).to eq(1)
    expect(markers.first.marker_name).to eq("AfterConfirmed")
    expect(markers.first.overrides).to eq({ "name" => "::String" })
  end

  it "skips ivars without a corresponding attr_reader/attr_accessor" do
    # `@internal_state` narrowed but no reader — the marker would be
    # unobservable from any caller, so skip.
    markers = described_class.synthesize(
      inferred_entries: [
        entry(
          class_name: "Venue",
          method_name: :ready?,
          when_true_ivars: { :"@internal_state" => string_type }
        )
      ],
      target_class: "Venue",
      members: []
    )

    expect(markers).to be_empty
  end

  it "ignores entries for other classes" do
    # The analyzer scopes per-file; we shouldn't accidentally emit a
    # marker for class B inside class A's RBS file.
    markers = described_class.synthesize(
      inferred_entries: [
        entry(
          class_name: "OtherClass",
          method_name: :confirmed?,
          when_true_ivars: { :"@name" => string_type }
        )
      ],
      target_class: "Venue",
      members: [member(kind: :attr_accessor, name: "name")]
    )

    expect(markers).to be_empty
  end

  it "ignores entries that only have unconditional narrowing" do
    # Setter-style entries are handled by `SetterMarkerSynthesizer`.
    # This synthesizer focuses on `when_true` narrowings; mixing
    # would double-emit markers for the same method.
    markers = described_class.synthesize(
      inferred_entries: [
        entry(
          class_name: "Venue",
          method_name: :set_default_name,
          ivars: { :"@name" => string_type },
          self_type_string: "::Venue & ::Venue::AfterSetDefaultName"
        )
      ],
      target_class: "Venue",
      members: [member(kind: :attr_accessor, name: "name")]
    )

    expect(markers).to be_empty
  end

  it "skips singleton entries" do
    markers = described_class.synthesize(
      inferred_entries: [
        entry(
          class_name: "Venue",
          method_name: :self_check?,
          singleton: true,
          when_true_ivars: { :"@name" => string_type }
        )
      ],
      target_class: "Venue",
      members: [member(kind: :attr_accessor, name: "name")]
    )

    expect(markers).to be_empty
  end

  it "produces markers sorted by marker_name for deterministic output" do
    markers = described_class.synthesize(
      inferred_entries: [
        entry(
          class_name: "Venue",
          method_name: :zebra?,
          when_true_ivars: { :"@name" => string_type }
        ),
        entry(
          class_name: "Venue",
          method_name: :alpha?,
          when_true_ivars: { :"@name" => string_type }
        )
      ],
      target_class: "Venue",
      members: [member(kind: :attr_accessor, name: "name")]
    )

    expect(markers.map(&:marker_name)).to eq(["AfterAlpha", "AfterZebra"])
  end

  it "agrees with Steep::Postconditions::MarkerNaming naming convention" do
    # The marker class generated here must match exactly what
    # `Steep::Postconditions::Inferrer` writes into the sidecar's
    # `when_true.self` slot. Drift would mean the sidecar references
    # a marker that doesn't exist in RBS, which triggers the
    # defensive guard on the consumer side and silently no-ops the
    # refinement.
    expected = Steep::Postconditions::MarkerNaming.marker_name_for("Venue", :confirmed?)
    expect(expected).to eq("::Venue::AfterConfirmed")

    markers = described_class.synthesize(
      inferred_entries: [
        entry(
          class_name: "Venue",
          method_name: :confirmed?,
          when_true_ivars: { :"@name" => string_type },
          when_true_self_type_string: expected
        )
      ],
      target_class: "Venue",
      members: [member(kind: :attr_accessor, name: "name")]
    )

    expect(markers.first.marker_name).to eq("AfterConfirmed")
  end
end
