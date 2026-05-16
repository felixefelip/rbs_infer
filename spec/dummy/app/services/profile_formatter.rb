# frozen_string_literal: true

# Fixture for the Steep fork's auto-inferred precondition contracts
# (felixefelip/steep#2 Phase 2).
#
# Plain Ruby attr_readers are treated as pure by Steep (Members::Attribute),
# so `nickname.upcase` in `format_nickname` triggers the inferrer to capture
# the obligation `not_nil(self.nickname)` and emit it in the sidecar at
# `sig/generated/.steep_contracts.yml`. The next `steep check` reads the
# sidecar and narrows the body, so neither line errors out.
class ProfileFormatter
  attr_reader :nickname

  def initialize(nickname:)
    @nickname = nickname
  end

  # o retorno deveria ser `String?`
  def call
    return unless nickname

    format_nickname
  end

  # Intentional fixture: this caller of `format_nickname` skips the nil-check
  # that `call` performs above. Phase 1's call-site verification catches it
  # and emits `PreconditionUnsatisfied`, which lands in
  # `spec/expectations/steep_baseline.txt` as the demonstration entry for the
  # contracts feature.
  def call_without_check
    format_nickname
  end

  private

  def format_nickname
    nickname.upcase
  end
end
