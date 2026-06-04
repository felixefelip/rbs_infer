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

    # Call-site kwarg de `Current.with` (rbs_infer#19): segunda fonte de
    # tipo para o atributo `user`, na forma com bloco (restaura ao sair).
    # `User.first` → `User?` exercita o merge nilável no pool da ivar.
    # (`User.first!` retornaria `User & User::Validated`, cujo union com
    # `User` é deliberadamente não simplificado — ver IvarTypeSet.)
    Current.with(user: User.first) do
      ProfileFormatter.new(nickname: "ada").call
    end
  end
end
