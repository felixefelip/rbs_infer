# frozen_string_literal: true

# A plain class whose ONLY call site is inside a concern, constructed with
# `self` — `WidgetAuditor.new(self)` in `Widget::Closeable`.
#
# What `self` is there is not in the file: it is whoever includes the module,
# which the mixin graph knows (`Widget`) and the self-type annotators state as
# `(Widget & Widget::Closeable)`. The caller-file walk was wired with that map;
# `MethodTypeResolver`'s two walks over the same files were not, and those are
# the ones that decide an `initialize` parameter — so this parameter came out
# `untyped`, and `@widget`/`attr_reader widget` with it.
#
# Found in Fizzy as `Card::ActivitySpike::Detector.new(self)` inside
# `Card::Stallable` (and `Account::Seeder.new(self, …)` inside
# `Account::Seedeable`). The cost is not only the parameter: with it untyped,
# Steep infers no precondition for any method of the class, and 256 lines of
# `.steep_contracts.yml` — every `Detector#*` and `Seeder#*` entry — disappeared
# (felixefelip/rbs_infer#175).
class WidgetAuditor
  attr_reader :widget

  def initialize(widget)
    @widget = widget
  end

  # Reads a method the HOST has, not the concern: it only resolves while the
  # parameter carries the intersection.
  def audit
    widget.published?
  end
end
