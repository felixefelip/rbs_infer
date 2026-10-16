# A class-level registry filled in class bodies and read back by literal key —
# the shape of Active Record's `_reflections` (`add_reflection` in the class
# body, `_reflect_on_association(name)` at run time), felixefelip/rbs_infer#394:
#
#   - the registry is a hash memoized in a class-instance ivar, written only
#     through its reader (`registry[name] = value`);
#   - each subclass's body registers its own literal keys;
#   - an instance method reads one back with the same literal.
#
# `Car#wheel` is a `Wheel` and `Car#seat` a `Seat`. `Truck` registers `:seat`
# as a `Bench`: each class holds its own hash, so that must not reach `Car`.
#
# Nothing here states a type.
module Example94
  class Wheel; end
  class Seat; end
  class Bench; end
  class Door; end

  class Base
    def self.registry
      @registry ||= {}
    end

    def self.register(name, value)
      registry[name] = value
    end

    def self.lookup(name)
      registry[name]
    end
  end

  class Car < Base
    register :wheel, Wheel.new
    register :seat, Seat.new

    def wheel = self.class.lookup(:wheel)
    def seat = self.class.lookup(:seat)
  end

  class Truck < Base
    register :seat, Bench.new
    register :door, Door.new

    def seat = self.class.lookup(:seat)
    def door = self.class.lookup(:door)
  end
end
