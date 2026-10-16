# A class-level registry filled in class bodies and read back by literal key —
# the shape of Active Record's `_reflections` (`add_reflection` in the class
# body, `_reflect_on_association(name)` at run time), felixefelip/rbs_infer#394:
#
#   - the registry is a hash memoized in a class-instance ivar, written only
#     through its reader (`registry[name] = value`);
#   - each subclass's body registers its own literal keys;
#   - a macro later in the same body reads one back and writes a method with
#     what it found, the way `has_many` reads its reflection;
#   - an instance method reads one back with the same literal.
#
# `Car#wheel` is a `Wheel` and `Car#seat` a `Seat`. `Truck` registers `:seat`
# as a `Bench`: each class holds its own hash, so that must not reach `Car`.
# So `Car#seat_label` is `:cushioned` and `Truck#seat_label` is `:bench`.
#
# Nothing here states a type.
module Example94
  class Wheel
    def label = :spoked
  end

  class Seat
    def label = :cushioned
  end

  class Bench
    def label = :bench
  end

  class Door
    def label = :sliding
  end

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

    def self.describe(name)
      class_eval "def #{name}_label = :#{lookup(name).label}"
    end
  end

  class Car < Base
    register :wheel, Wheel.new
    register :seat, Seat.new
    describe :wheel
    describe :seat

    def wheel = self.class.lookup(:wheel)
    def seat = self.class.lookup(:seat)
  end

  class Truck < Base
    register :seat, Bench.new
    register :door, Door.new
    describe :seat

    def seat = self.class.lookup(:seat)
    def door = self.class.lookup(:door)
  end
end
