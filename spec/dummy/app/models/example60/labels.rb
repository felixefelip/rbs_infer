# `delegate ..., to: :class` — the concern half.
#
# Two things were wrong in the one line this generates. The parameter list was
# not copied at all: the delegated method was emitted as `() -> <return>`
# whatever the target accepted, a signature its own call sites contradict. And
# `to: :class` was read by capitalizing the reader's name, which for `class`
# is the constant `Class` — so every lookup went to `::Class`, which has none
# of these methods, and even the return type came out by accident
# (felixefelip/rbs_infer#294).
#
# `to: :class` forwards to `self.class`, and inside a concern that is the HOST:
# the class methods live in `Example60::Labels::ClassMethods`, which only
# `singleton(Example60)` reaches.
module Example60::Labels
  extend ActiveSupport::Concern

  delegate :human_name, to: :class

  class_methods do
    def human_name(index)
      index.upcase
    end
  end
end
