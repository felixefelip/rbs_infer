# A class whose included module OVERRIDES a method another included module
# declares, with a body of a DIFFERENT type. `Example66Trackable#relevant?`
# answers `false` (`bool`); the override answers `flagged?`, an accessor never
# initialized, so the honest type is `bool?` — `nil` until `mark!` runs.
#
# What the snapshot records is the wrong one, `() -> bool`, and Steep rejects it
# against the body it can see.
#
# `ReturnTypeResolver#improve_method_return_types` fills a still-`untyped` member
# from `known_return_types`, a map keyed by NAME alone: it answers with a
# DECLARATION — the module's, or this class's own from the previous run — and the
# member stops being `untyped` right there, so the Steep pass below, which reads
# the body and says `bool?`, is never asked. A declaration is not evidence about
# a body, and an override is exactly where the two part ways.
#
# Three things have to line up for the declaration to win, and all three are
# ordinary:
#   - the def is spliced from an `included do`, so it is absent from the file
#     `MethodTypeResolver` parses for this class and its step 1b never resolves
#     the body;
#   - the body reads an ALIAS, which the pre-Steep passes do not resolve, so the
#     member is still `untyped` when the declaration lookup answers;
#   - this class's RBS already exists (every run after the first), so
#     `build_class_types` step 6/7 has a declaration to hand over.
#
# Read off fizzy: `Card#should_check_mentions?` overrides the `Mentions` concern's
# template method with `was_just_published?`, and Steep answers `Cannot allow
# method body have type (bool | nil) because declared as type bool`.
class Example66
  include Example66Trackable
  include Example66Override
end

class Example66
  def relevant?
    flagged?
  end
end
