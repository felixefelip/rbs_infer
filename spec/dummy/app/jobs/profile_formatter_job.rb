# frozen_string_literal: true

# Provides rbs_infer with caller-side evidence for `ProfileFormatter#initialize`,
# so the generated RBS pins the param (and the propagated `@nickname` /
# `attr_reader nickname`) as `String?`. `["", nil].sample` returns
# `(String | nil)` per the standard library RBS for `Array#sample`, which
# is exactly the shape we want for the precondition-fixture scenario.
class ProfileFormatterJob < ApplicationJob
  def perform
    # Two explicit call sites give rbs_infer caller-side evidence that
    # `nickname` is `(String | nil)`. The naturally expressive
    # `["", nil].sample` form would be nicer, but rbs_infer's
    # NodeTypeInferrer doesn't yet resolve Array-literal element types
    # through method calls — tracked in
    # `docs/tasks/type_inference_gaps.md`.
    ProfileFormatter.new(nickname: "ada").call
    ProfileFormatter.new(nickname: nil).call
  end
end
