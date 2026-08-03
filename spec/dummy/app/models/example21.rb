# A parameter typed as the RECEIVER of the expression assigned to it.
#
# The caller-side map that types an argument is keyed by `line:column`
# (`SteepBridge#all_expression_types`, felixefelip/rbs_infer#155). A receiver
# starts exactly where its call does — in
#
#     Registry.holder = ticket.holder
#
# both `ticket` and `ticket.holder` begin at the same column — so the two share
# one key and whichever `each_typing` yields last takes it.
#
# It stays hidden while the call itself has a type, because then either answer
# is at least about the right expression. It surfaces when the call is
# `untyped`: here `ticket` is nilable, so Steep types `ticket.holder` as
# `untyped`, the map drops it, and the receiver is left answering for the whole
# expression. `holder=` then takes a `Ticket?`, which is the object that HAS a
# holder rather than the holder.
#
# Found in Fizzy, where `Current#identity=` came out as
#
#     def identity=: ((Identity | (Session & Session::Validated)?) identity) -> untyped
#
# from `self.identity = session.identity`. It does not stop there: `@identity`
# takes the parameter's type, and `@user` takes it in turn through
# `self.user = identity.users.find_by(…)` — the same collision, one level on,
# with the already-polluted `identity` as the receiver. Every `Current.identity`
# in the app is a `Session` as far as the checker knows.
#
# Two shapes that do NOT fix it, both measured: preferring the widest
# expression at a position, and preferring the narrowest. The key names a
# position, and a position does not name an expression — `Example10::Sink.last=`
# and `Current.with` in this same dummy want the INNER answer, for the mirror
# reason. Only a key that carries the range can tell the two apart.
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

  # The whole fixture. `Registry.holder=` should take a `Holder`; it takes
  # whatever `ticket` is.
  def promote
    Registry.holder = ticket.holder
  end

  # And where that lands: the registry hands back a `Ticket?`, which has no
  # `name`. Until the map can tell an expression from a position, this is an
  # error the real code does not have.
  def show
    "Held by #{Registry.holder.name}"
  end
end
