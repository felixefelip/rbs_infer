# frozen_string_literal: true

# A method the base class calls on `self`, defined only by its subclasses.
# `introduce` is written once, on `Animal`, and runs on a dog or a cat: a reader
# of `Example105Caller` knows `speak` receives the `String` `introduce` passes,
# in both `Example105Dog` and `Example105Cat`.
class Example105
  class Animal
    def introduce
      speak("hello")
    end
  end
end
