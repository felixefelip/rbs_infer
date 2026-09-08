# The other handler, taking types that share nothing with `Greeter`'s. That is
# the point of having two: the receiver is the only thing separating their call
# sites, so if the fix loses it, one of these takes the other's arguments.
class Example65Adder < Example65::Dispatcher
  def handle(count, step:)
    count + step
  end
end
