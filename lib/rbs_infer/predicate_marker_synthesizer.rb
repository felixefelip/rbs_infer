module RbsInfer
  # Generates marker class declarations for predicate-narrowing
  # methods (`def confirmed?; !@name.nil?; end`) by reading Steep's
  # `Postconditions::Inferrer` output directly. The inferrer is
  # authoritative for "what does this method narrow?" — using its
  # `InferredEntry` records keeps marker emission aligned with
  # whatever shapes Steep's `LogicTypeInterpreter` recognizes today
  # or in the future.
  #
  # Symmetric to `SetterMarkerSynthesizer` (which handles
  # `unconditional.ivars` narrowings — setters that assign literals
  # to ivars). This one handles `when_true.ivars` — predicates whose
  # truthy branch narrows ivars to a non-nil residual. Both produce
  # `MarkerClass` structs with the same shape, and the analyzer
  # merges their outputs into a single set of nested classes.
  class PredicateMarkerSynthesizer
    # Reuses `SetterMarkerSynthesizer::MarkerClass` so the analyzer
    # and `RbsBuilder` consume one shape regardless of origin.
    MarkerClass = SetterMarkerSynthesizer::MarkerClass

    # @param inferred_entries [Array<Steep::Postconditions::InferredEntry>]
    #   The entries `Steep::Postconditions::Inferrer.infer(...)` returned
    #   for the source under analysis.
    # @param target_class [String] only entries matching this class
    #   contribute markers — the analyzer scopes synthesis per file.
    # @param members [Array<RbsInfer::Inference::Member>] used to confirm a
    #   reader exists for each narrowed ivar (an
    #   `attr_reader`/`attr_accessor`); without one the marker would
    #   be unobservable.
    # @return [Array<MarkerClass>]
    def self.synthesize(inferred_entries:, target_class:, members:)
      new(inferred_entries: inferred_entries, target_class: target_class, members: members).synthesize
    end

    def initialize(inferred_entries:, target_class:, members:)
      @inferred_entries = inferred_entries
      @target_class = normalize_class_name(target_class)
      @members = members
    end

    def synthesize
      reader_ivars = collect_reader_ivars

      markers = []
      @inferred_entries.each do |entry|
        next unless normalize_class_name(entry.class_name) == @target_class
        next if entry.singleton
        next if entry.when_true_ivars.nil? || entry.when_true_ivars.empty?

        overrides = filter_observable_overrides(entry.when_true_ivars, reader_ivars)
        next if overrides.empty?

        marker_name = marker_short_name_for(entry.method_name)
        next unless marker_name

        markers << MarkerClass.new(
          method_name: entry.method_name.to_s,
          marker_name: marker_name,
          overrides: overrides
        )
      end
      markers.sort_by(&:marker_name)
    end

    private

    def collect_reader_ivars
      @members
        .select { |m| [:attr_reader, :attr_accessor].include?(m.kind) }
        .map(&:name)
        .to_set
    end

    # Keep only ivar refinements whose name matches a public reader
    # on the class. A predicate that narrows `@internal_state` to
    # non-nil is correct, but without `attr_reader :internal_state`
    # there's no exposed path for callers to observe the refinement
    # — the marker would be sidecar/RBS noise.
    def filter_observable_overrides(when_true_ivars, reader_ivars)
      overrides = {}
      when_true_ivars.each do |ivar_sym, refined_type|
        ivar_name = ivar_sym.to_s.sub(/\A@/, "")
        next unless reader_ivars.include?(ivar_name)
        overrides[ivar_name] = format_type(refined_type)
      end
      overrides
    end

    # The `InferredEntry` carries `Steep::AST::Types::t` instances; we
    # need RBS-printable strings for the `attr_reader x: Type` line.
    # `Steep::AST::Types::*#to_s` already produces RBS-compatible
    # output (with leading `::`); use it directly.
    def format_type(type)
      type.to_s
    end

    def marker_short_name_for(method_name)
      return nil unless Steep::Postconditions::MarkerNaming.valid_method_name?(method_name)
      "After#{Steep::Postconditions::MarkerNaming.pascal_case(method_name)}"
    end

    def normalize_class_name(name)
      name.to_s.sub(/\A::/, "")
    end
  end
end
