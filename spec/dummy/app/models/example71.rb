# Where a `class_eval` of a string lands — felixefelip/steep#175.
#
# What the eval WRITES is not in question here. The checker reads the type of the
# ARGUMENT and never the receiver, so every string below folds to a literal, and
# a literal is its own source. What decides whether it is placed is WHERE it
# lands, and the sidecar has no field for that: the consumer works it out from
# the class whose body holds the macro call. So the only receivers read are the
# ones that provably ARE that class — `self` (felixefelip/steep#173), and an
# argument a caller was seen to hand its own self to (felixefelip/steep#174).
#
# The two that are declined below are declined for a reason that is not
# ignorance: each names its class in the source, and one of them names it more
# exactly than `self` does.
module Example71
  class Target
  end

  class Host
    # Lands, and the RBS below has it: `self` inside a method called on this
    # class IS this class.
    def self.writes_on_self(name)
      self.class_eval "def #{name}; :self; end"
    end

    # Should land on `Target` and does not. The receiver is a constant — the
    # target is written on the line, which is MORE determined than `self`, since
    # `self` still depends on who called. The sidecar has nowhere to put it.
    def self.writes_on_constant(name)
      Target.class_eval "def #{name}; :constant; end"
    end

    # Same, through a local. The question is the type of the receiver, not the
    # shape of the expression that produced it, so this is the previous case
    # with one assignment in front of it.
    def self.writes_on_local(name)
      target = Target
      target.class_eval "def #{name}; :local; end"
    end

    writes_on_self :from_self
    writes_on_constant :from_constant
    writes_on_local :from_local
  end

  # The half of #175 that is a REGRESSION GUARD rather than a gap.
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
  # `from_mixin` is missing from the RBS below, and NOT for the reason the rest
  # of this file is about. The checker folds it and records it; it is addressed
  # to the wrong LINE. `STEEP_MODULE_CONVENTION` injects an annotation at the
  # `Writes` anchor, the call below sits after it, and the position is written in
  # the injected file's coordinates while the consumer reads this one
  # (felixefelip/steep#176). The two calls above the anchor are recorded exactly,
  # which is what makes that unambiguous — and what makes this fixture worth more
  # than the gap it was written for.
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
