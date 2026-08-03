# A parameter typed as the RECEIVER of the expression assigned to it — the
# collision that keying the map by RANGE resolves (felixefelip/rbs_infer#168).
#
# The caller-side map that types an argument used to be keyed by `line:column`
# (`SteepBridge#all_expression_types`, felixefelip/rbs_infer#155). A receiver
# starts exactly where its call does — in
#
#     Registry.holder = ticket.holder
#
# both `ticket` and `ticket.holder` begin at the same column — so the two shared
# one key and whichever `each_typing` yielded last took it.
#
# It stayed hidden while the call itself had a type, because then either answer
# was at least about the right expression. It surfaced when the call was
# `untyped`: here `ticket` is nilable, so Steep types `ticket.holder` as
# `untyped`, the map dropped it, and the receiver was left answering for the
# whole expression. `holder=` then took a `Ticket?`, which is the object that
# HAS a holder rather than the holder.
#
# Found in Fizzy, where `Current#identity=` came out as
#
#     def identity=: ((Identity | (Session & Session::Validated)?) identity) -> untyped
#
# from `self.identity = session.identity`. It did not stop there: `@identity`
# took the parameter's type, and `@user` took it in turn through
# `self.user = identity.users.find_by(…)` — the same collision, one level on,
# with the already-polluted `identity` as the receiver. Every `Current.identity`
# in the app was a `Session` as far as the checker knew.
#
# Two shapes that do NOT fix it, both measured: preferring the widest
# expression at a position, and preferring the narrowest. The key named a
# position, and a position does not name an expression — `Example10::Sink.last=`
# and `Current.with` in this same dummy want the INNER answer, for the mirror
# reason. Only a key that carries the range tells the two apart, which is what
# the map is keyed by now.
class Example21
  class Holder
    attr_reader :name

    def initialize(name:)
      @name = name
    end
  end

  class Ticket
    def holder
      Holder.new(name: "holder")
    end
  end

  class Registry
    def self.holder=(value)
      @holder = value
    end

    def self.holder
      @holder
    end
  end

  # Nilable on purpose: it is what makes the call below `untyped`, and the
  # receiver the only typed thing left at that position. So `ticket.holder` is
  # itself a recorded error — the precondition, not the bug.
  def ticket
    @ticket
  end

  def assign(ticket)
    @ticket = ticket
  end

  # So the reader above has a type to be nilable OF. Without it `ticket` is
  # `untyped` and there is nothing for the receiver to answer WITH.
  def prepare
    assign(Ticket.new)
  end

  # The whole fixture. `Registry.holder=` used to take whatever `ticket` is; it
  # now takes `untyped`, which is what the assigned expression really has — the
  # call below is itself the error the baseline records, so the checker types it
  # with nothing rather than with the receiver.
  #
  # `Holder` is what a human reads here, and reaching it is a separate step: the
  # structural chain asks the caller class's method map for `ticket` and gets
  # `untyped`, where `MethodTypeResolver#resolve` answers `Example21::Ticket?`
  # for the same question — and `resolve("Example21::Ticket?", "holder")` is
  # already `Example21::Holder`.
  def promote
    Registry.holder = ticket.holder
  end

  # And where that lands: the registry used to hand back a `Ticket?`, which has
  # no `name` — an error the real code does not have. It hands back what was
  # actually assigned now, so this line is clean.
  def show
    "Held by #{Registry.holder.name}"
  end
end
