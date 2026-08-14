# frozen_string_literal: true

require "prism"
require "steep/postconditions/marker_naming"
require_relative "self_class_eval_expander"

module RbsInfer::Project
  # WHEN the methods a `self.class.class_eval` defines come into existence.
  #
  # `SelfClassEvalExpander` answers WHERE they land — on the enclosing class —
  # and that alone says they are always there. They are not: `build_age` is what
  # puts them there, so a call that precedes it raises `NoMethodError`, and
  # declaring them on the class outright is what makes the checker stop saying
  # so (felixefelip/rbs_infer#245).
  #
  # The fix is the marker the fork already has for exactly this shape of fact:
  #
  #   * the `def`s are declared on `Foo::AfterBuildAge`, not on `Foo`;
  #   * `build_age` carries `unconditional.self: "::Foo & ::Foo::AfterBuildAge"`,
  #     so calling it narrows the receiver to the intersection.
  #
  # A read before the call sees plain `Foo`, which has no `age` — the original
  # error, now for the reason that is actually true. A read after sees the
  # intersection, which has it.
  #
  # STRICTER than runtime, deliberately: `class_eval` mutates the CLASS, so
  # `other.build_age` makes `age` real for every instance, and the marker follows
  # only the receiver it was called on. That is the same "prove it from the call
  # sites you can see" the analyzer applies everywhere else, and the alternative
  # — declaring `age` unconditionally — is what this exists to stop.
  #
  # Both halves are keyed to the same marker name, composed by Steep's own
  # `MarkerNaming` so the two ends cannot drift: a marker the RBS does not
  # declare makes `apply_unconditional_postconditions` silently no-op.
  #
  # One diagnostic survives and belongs in the baseline: Steep reads the `def`s
  # in the ORIGINAL block against the enclosing class, where they are no longer
  # declared, and says so. The `blocks:` sidecar that would redirect them at the
  # marker matches only RECEIVERLESS calls, and this call has `self.class` as its
  # receiver — so pointing it there needs a wider matcher on the Steep side than
  # this change is buying.
  module SelfClassEvalMarker
    module_function

    # @return [Array<Hash>] `[{ target:, method:, marker:, narrowed_self: }]`,
    #   one per relocated block whose method can name a marker, else `[]`.
    #
    # The name comes from the expander, which is what writes it into the RBS —
    # composing it a second time here is how the two ends drift apart, and a
    # marker the RBS does not declare makes the narrowing silently no-op.
    def markers_for(source)
      expander = RbsInfer::Project::SelfClassEvalExpander

      expander.relocations(source).filter_map do |relocation|
        marker = expander.marker_for(relocation) or next

        {
          target: relocation.target,
          method: relocation.method,
          marker: marker,
          narrowed_self: "::#{relocation.target} & #{marker}"
        }
      end
    end

    # The `.steep_postconditions.yml` entries: calling the method narrows the
    # receiver to the intersection that carries the new methods.
    def postconditions_for(source)
      markers_for(source).map do |marker|
        {
          "class" => marker[:target],
          "method" => marker[:method],
          "unconditional" => { "self" => marker[:narrowed_self] }
        }
      end
    end

  end
end
