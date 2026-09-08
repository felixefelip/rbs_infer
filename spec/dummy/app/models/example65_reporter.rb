# The handler whose ONLY call site names a subclass of its own class, not itself
# — `Example65CsvReporter.dispatch("/tmp/x.csv")` below. A subclass that adds
# nothing still runs this handler, so the type is there to be read.
#
# Matching the dispatch site on "the receiver IS the target" discarded it and
# left `path` untyped, which is narrower than the truth rather than merely
# absent. It is also what the ordinary path already accepts: for a direct
# `reporter.handle(path)` with `reporter : Example65CsvReporter`,
# `ancestry_match_key` matches on the OWNER being the target. The two paths ask
# the same question now.
class Example65Reporter < Example65::Dispatcher
  def handle(path)
    path.upcase
  end
end
