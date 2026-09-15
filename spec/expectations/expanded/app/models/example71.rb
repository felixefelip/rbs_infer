# Where a `class_eval` of a string lands — felixefelip/steep#175.
#
# What the eval WRITES is not in question here. The checker reads the type of the
# ARGUMENT and never the receiver, so every string below folds to a literal, and
# a literal is its own source. WHERE it lands is the receiver's business, and the
# two answers below come from different places.
#
# A chunk that NAMES its class carries it: the receiver's type is a
# `singleton(X)` for a concrete X, which is as true of a local holding the
# constant as of the constant itself. Anything else is placed by the class whose
# body lexically holds the macro call — `self` (felixefelip/steep#173), and an
# argument a caller was seen to hand its own self to (felixefelip/steep#174).
#
# The order matters and is the point of the second half of this file: `self` is
# a type VARIABLE, so reading a target off it would place a macro's methods on
# the class that DEFINES the macro rather than the one that called it. The
# lexical rule is what gets that right, and it keeps those cases.
module Example71
  class Target
  end

  class Host
    # Lands, and the RBS below has it: `self` inside a method called on this
    # class IS this class.
    def self.writes_on_self(name)
      self.class_eval "def #{name}; :self; end"
    end

    # Lands on `Target`, and says so: the receiver is a constant, so its type
    # names the class exactly — MORE exactly than `self` does, since `self`
    # still depends on who called. The chunk carries `::Example71::Target` and
    # the RBS below puts the method there rather than on `Host`.
    def self.writes_on_constant(name)
      Target.class_eval "def #{name}; :constant; end"
    end

    # Same, through a local, and the same answer: what decides is the TYPE of
    # the receiver, not the shape of the expression that produced it. The local
    # keeps `singleton(Example71::Target)`, so this is the previous case with an
    # assignment in front of it.
    def self.writes_on_local(name)
      target = Target
      target.class_eval "def #{name}; :local; end"
    end

    writes_on_self :from_self
    writes_on_constant :from_constant
    writes_on_local :from_local
  end

  # The half of #175 that is a REGRESSION GUARD rather than a gap — and the
  # reason the rule above is the receiver's TYPE naming a class, rather than
  # "place it wherever the receiver points".
  #
  # A macro normally lives on a base class and is called on a subclass, and the
  # receiver of the eval is then typed `self` — a type variable, not a class
  # name. Placing by the receiver's TYPE would put `from_inherited` on `Base`;
  # what puts it on `Child`, correctly, is the rule this file is about — the
  # class whose body holds the call.
  #
  # So `from_inherited` appearing under `Child` below is not incidental. It is
  # the case a naive `target:` field would break, and the dummy's ActionText
  # models are the same shape.
  class Base
    def self.writes(name)
      self.class_eval "def #{name}; :inherited; end"
    end
  end

  class Child < Base
    writes :from_inherited
  end

  # The same guard for the shape Rails actually uses — a concern's `ClassMethods`
  # is a MODULE, and `self` inside one of its methods is the class that extended
  # it, so `from_mixin` belongs to `Mixed`. It is worth having beside the
  # inherited case because the naive target is wrong in a DIFFERENT way here:
  # read off the receiver's type, `from_inherited` would land on `Base` — the
  # wrong class, in the right tree — and `from_mixin` on `Writes`, which is not a
  # class at all and which nothing calling `from_mixin` would ever look at.
  #
  # `from_mixin` lands, and for a while it did not — for a reason that had
  # nothing to do with the rest of this file. The checker folded it and recorded
  # it, addressed to the wrong LINE: `STEEP_MODULE_CONVENTION` injected its
  # annotation as a new line at the `Writes` anchor, the call below sits after
  # it, and the position was written in the injected file's coordinates while
  # the consumer reads this one. The two calls above the anchor were recorded
  # exactly, which is what made the cause unambiguous (felixefelip/steep#176,
  # fixed by attaching the annotation to its node instead of writing it into the
  # source).
  #
  # Left as it is, comments and all, because a file where a module precedes a
  # macro call is the shape that found it.
  module Writes
    def writes_mixed(name)
      self.class_eval "def #{name}; :mixed; end"
    end
  end

  class Mixed
    extend Writes

    writes_mixed :from_mixin
  end
end

class Example71::Host
  def from_self; :self; end
end

class Example71::Target
  def from_constant; :constant; end
  def from_local; :local; end
end

class Example71::Child
  def from_inherited; :inherited; end
end

class Example71::Mixed
  def from_mixin; :mixed; end
end
