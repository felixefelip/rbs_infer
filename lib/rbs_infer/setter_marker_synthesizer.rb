require "steep/postconditions/marker_naming"

module RbsInfer
  # Produces "marker" class declarations to attach to a generated RBS
  # so that Steep's `unconditional.self` postcondition refinements have
  # a real type to intersect with. See felixefelip/rbs_infer#11 and the
  # companion `Steep::Postconditions::Inferrer` change which emits the
  # matching `unconditional.self: "::Foo & ::Foo::AfterX"` sidecar.
  #
  # Without these markers, the sidecar references a class that doesn't
  # exist in RBS and `apply_unconditional_postconditions` silently no-ops
  # — the type checker sees no narrowing.
  #
  # Generation rule (V1, matching the issue spec):
  #
  #   For each method M of class C:
  #     - Find ivars M assigns whose narrowed write type differs from
  #       the declared (class-level) type — that's a refinement.
  #     - For each such ivar, check that C has a reader for it
  #       (`attr_reader` / `attr_accessor`). Without a reader the
  #       marker would be unobservable; skip.
  #     - Emit `class C::After<M_pascal> { attr_reader <ivar>: <narrowed> }`.
  #
  # Singletons are already filtered by `SteepBridge#ivar_write_types_per_method`
  # (it skips `:defs` nodes), so the singleton case doesn't need
  # explicit handling here.
  class SetterMarkerSynthesizer
    # Output: list of marker class declarations, sorted by marker name
    # so the RBS output is deterministic across runs.
    #
    #   method_name  : "set_default_name"        (no `self.` prefix; singletons already filtered)
    #   marker_name  : "AfterSetDefaultName"     (short form — used as a nested class inside parent)
    #   overrides    : { "name" => "String" }    (ivar name without leading `@` → narrowed type str)
    MarkerClass = Struct.new(:method_name, :marker_name, :overrides, keyword_init: true)

    # @param members [Array<RbsInfer::Member>] members of the target class
    # @param ivar_write_types_per_method [Hash{String=>Hash{String=>String}}]
    #   from `SteepBridge#ivar_write_types_per_method` — method name →
    #   ivar name (no `@`) → narrowed type string
    # @param declared_ivar_types [Hash{String=>String}] declared (wide
    #   union) ivar types, keyed by ivar name without `@`. Built by the
    #   analyzer from `infer_ivar_types` + `attr_types`.
    # @return [Array<MarkerClass>]
    def self.synthesize(members:, ivar_write_types_per_method:, declared_ivar_types:)
      new(
        members: members,
        ivar_write_types_per_method: ivar_write_types_per_method,
        declared_ivar_types: declared_ivar_types
      ).synthesize
    end

    def initialize(members:, ivar_write_types_per_method:, declared_ivar_types:)
      @members = members
      @ivar_write_types_per_method = ivar_write_types_per_method
      @declared_ivar_types = declared_ivar_types
    end

    def synthesize
      reader_ivars = collect_reader_ivars

      markers = []
      @ivar_write_types_per_method.each do |method_name, ivar_types|
        overrides = filter_overrides(ivar_types, reader_ivars)
        next if overrides.empty?

        marker_name = marker_short_name_for(method_name)
        next unless marker_name

        markers << MarkerClass.new(
          method_name: method_name,
          marker_name: marker_name,
          overrides: overrides
        )
      end
      markers.sort_by(&:marker_name)
    end

    private

    # Ivars that have an `attr_reader` or `attr_accessor` declared on
    # the class. Manual `def name; @name; end` getters are out of scope
    # for V1 — the test would have to distinguish "method that just
    # reads the ivar" from "method that does other stuff", which is a
    # larger commitment than the marker output warrants.
    def collect_reader_ivars
      @members
        .select { |m| [:attr_reader, :attr_accessor].include?(m.kind) }
        .map(&:name)
        .to_set
    end

    def filter_overrides(ivar_types, reader_ivars)
      overrides = {}
      ivar_types.each do |ivar_name, narrowed_type|
        next unless reader_ivars.include?(ivar_name)
        declared = @declared_ivar_types[ivar_name]
        next if declared.nil?
        next if same_type?(declared, narrowed_type)
        overrides[ivar_name] = narrowed_type
      end
      overrides
    end

    # Trivial string-equality after stripping outer parens. The
    # narrowed-vs-declared comparison can't easily be "strict subtype"
    # without re-parsing through RBS, but the inferrer upstream
    # (`ivar_write_types_per_method`) only returns the writer's actual
    # contribution — so "different from declared" is a safe proxy for
    # "narrowing happened." Equal types mean no refinement; emitting a
    # marker would be a no-op.
    def same_type?(a, b)
      normalize(a) == normalize(b)
    end

    # Whitespace-insensitive, parens-insensitive, and `T?`-as-`T|nil`
    # normalization. The goal isn't a full type-equality check (that
    # would require running through RBS::Parser); it's enough to keep
    # cosmetic differences (`(String | nil)` vs `String?` vs
    # `String | nil`) from masquerading as real narrowings.
    def normalize(type_string)
      s = type_string.to_s.gsub(/\s+/, "")
      s = s.sub(/\A\((.*)\)\z/, '\1')
      s = s.sub(/\?\z/, "|nil")
      s
    end

    # Delegates to the shared convention. `pascal_case` is the
    # snake_case → PascalCase part; we prepend "After" here to keep the
    # full prefix-and-segment rule visible in one place. Returns nil
    # for method names that strip to empty (e.g. `:"="`).
    def marker_short_name_for(method_name)
      return nil unless Steep::Postconditions::MarkerNaming.valid_method_name?(method_name)
      "After#{Steep::Postconditions::MarkerNaming.pascal_case(method_name)}"
    end
  end
end
