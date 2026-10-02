# The reflection branch of a delegation macro, read the way the checker reads
# any other value — felixefelip/steep#171, stage S2.
#
# example75 is the same macro without this: it writes `def email` with no
# parameters, because the methods it delegates take none. A real `delegate` has
# to write the parameter list of the method it forwards to, and the only place
# that list is written down is the target's own declaration. So the macro asks
# for it:
#
#   - `Peel.singleton_class` is the class whose instance methods are Peel's
#     class methods — a class the checker can NAME, where it used to answer
#     `::Class` and lose the identity one step before the reflection;
#   - `.public_instance_method(:human_name)` is that method, still knowing which
#     method it is;
#   - `.parameters` is `[[:req, :index]]`, folded out of
#     `def self.human_name: ("all" index) -> "ALL"` — the declaration beside
#     this file, which rbs_infer wrote on the pass before;
#   - `[0][1]` is `:index`, which needs no fold at all: indexing a tuple with a
#     literal is something the checker already does;
#   - so `"def #{method}(#{argument})"` is a literal, and a literal handed to
#     `class_eval` IS the source the call site writes (steep#169).
#
# Without S2 the third step answers `::Method::param_types`, the chunk is not a
# literal, and `StringEvalSidecar` drops it — the only chunk this call site
# writes — so `human_name` would not be `untyped` on `Peel`, it would not exist.
#
# The RBS beside this file is the result. `def human_name: ("all" index) ->
# "ALL"` on `Peel`: the parameter's NAME came out of the target's declaration
# through the reflection, its TYPE out of the one call site that passes `"all"`,
# and the return out of `index.upcase` folding. Nothing here states a type.
#
# `short_name` is the other half, and it is why `Half` exists. A nominal type
# names a class and `singleton(::Half)` is a `singleton(::Peel)`, so the class
# object a reflection ran on may be a subclass's — and `Half.short_name` takes a
# parameter `Peel.short_name` does not. What a method's parameter list IS does
# not survive an override the way its signature does, so the fold reads the
# subclasses and answers only where they agree. `human_name`, which `Half`
# leaves alone, is written; `short_name` is declined, and no instance method of
# that name is emitted for anyone.
#
# Two things measured while writing this, both of which decide its shape:
#
# The receiver of `singleton_class` is written out. `singleton_class` on its
# own, inside `def self.banana_delegate`, infers `::Class`: the receiver is then
# the SELF type, which names no class for the fold to reflect on. Writing
# `Peel.singleton_class` is the same object by a name the checker has.
#
# The owner is not a parameter, which is what `ActiveSupport::Delegation.generate`
# does (`generate(owner, methods, …)`). Written that way — `banana_delegate self,
# :human_name` — rbs_infer types the argument `untyped`, and an `untyped`
# parameter cancels the specialization, so no literal reaches the body and
# nothing folds at all. The macro names its class instead; the day a `self`
# argument carries its singleton type, this file is where that shows.
module Example76
  class Peel
    def self.human_name(index)
      index.upcase
    end

    # Delegated below and declined there: `Half` widens it.
    def self.short_name(index)
      index
    end

    def self.banana_delegate(method)
      argument = Peel.singleton_class.public_instance_method(method).parameters[0][1]

      class_eval [
        "def #{method}(#{argument})",
        "  self.class.#{method}(#{argument})",
        "end"
      ].join(";")
    end

    # type should be `("all" index) -> "ALL"` on `Peel`
    banana_delegate :human_name

    # Nothing should be written for this one: the parameter list depends on
    # which class the reflection ran on, and the two do not agree.
    banana_delegate :short_name
  end

  # The subclass that makes `short_name` undecidable, and leaves `human_name`
  # alone.
  class Half < Peel
    def self.short_name(index, extra = "!")
      index
    end
  end

  class Eater
    # The call site that types the generated method's parameter.
    def label
      Peel.new.human_name("all")
    end
  end
end

class Example76::Peel
  def human_name(index);  self.class.human_name(index);end
end
