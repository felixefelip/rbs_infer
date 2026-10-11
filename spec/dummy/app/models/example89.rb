# A string `class_eval` on a module the class builds and includes —
# felixefelip/steep#208, the shape Active Record defines association readers
# with (`generated_association_methods.class_eval "def #{name}; …"`).
#
# `generated_methods` builds `<self>::GeneratedMethods` with
# `const_set(:GeneratedMethods, Module.new)`, includes it, and memoizes it.
# `define_reader` evaluates its string on that module; `define_reader_on_self`
# evaluates the same string on `self`, as the control.
#
# Today the module is typed `Module`, which names no place to put the code: the
# two `define_reader` call sites are not recorded in `.steep_string_evals.yml`,
# `size` and `weight` are never defined, and `generated_methods` reads
# `() -> Module`. The two `define_reader_on_self` call sites fold and are
# placed, so `color` and `shape` are defined on `Widget`.
#
# Nothing here states a type.
module Example89
  class Base
    def self.generated_methods
      @generated_methods ||= begin
        mod = const_set(:GeneratedMethods, Module.new)
        include mod
        mod
      end
    end

    def self.define_reader(name)
      generated_methods.class_eval "def #{name}; 1; end"
    end

    def self.define_reader_on_self(name)
      class_eval "def #{name}; 1; end"
    end
  end

  class Widget < Base
    define_reader :size
    define_reader :weight
    define_reader_on_self :color
    define_reader_on_self :shape
  end

  class Use
    def self.size = Widget.new.size
    def self.weight = Widget.new.weight
    def self.color = Widget.new.color
  end
end
