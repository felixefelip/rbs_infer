# The one call site `human_name` has. Written through a local so the receiver
# is `singleton(Example60)`: the bare `Example60.human_name(...)` spelling is
# ambiguous, and the delegate below puts an INSTANCE `human_name` on the host
# too, which is what an ambiguous spelling would resolve to first.
class Example60Labeller
  def call
    klass = Example60
    klass.human_name("all")
  end
end
