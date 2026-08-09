# frozen_string_literal: true

# One of the two hosts of `IncludedHook::Shared`. Its own file, as Zeitwerk requires —
# and as `MixinIndex` requires too: the index reads one class per file (via
# `ClassNameExtractor`), so an `include` written in a secondary class of a shared file
# is attributed to that file's primary class instead.
class IncludedHookFirst
  include IncludedHook::Shared
end
