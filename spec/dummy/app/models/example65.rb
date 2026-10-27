# The template method — a handler each subclass implements, reached only through
# a dispatcher the BASE class defines. ActiveJob is the case that surfaced it
# (`perform` is never called by the app, `MyJob.perform_later(user)` is), and
# this is the same shape with no framework in it (felixefelip/rbs_infer#331).
#
# `Example65Greeter.dispatch(...)` is read as a call site of
# `Example65Greeter#handle`: the forward is inherited and transparent, and the
# receiver is kept. The two subclasses take unrelated types, so a filter too
# loose to separate them shows up as one taking the other's. `dispatch`'s own
# `*args` still receives every subclass's arguments, as it does at run time.
#
# The two handlers live in their own files for a measured reason: with all three
# `handle` methods in ONE file, every one of them reported the first's return
# type (`Example65Adder#handle`, which adds two Integers, came out `String`). That
# is a
# separate defect, and keeping it out of this file keeps this example about the
# parameters. (They are top-level constants because Zeitwerk names a file's
# constant after the file: `example65_greeter.rb` must define `Example65Greeter`.)
class Example65
  class Dispatcher
    # As ActiveJob writes it: the queue collapsed, the handler built and handed
    # the caller's arguments, and returned.
    def self.dispatch(*args, **kwargs)
      handler = new
      handler.handle(*args, **kwargs)
      handler
    end

    # Abstract, exactly as `ActiveJob::Execution#perform` is — the arity is
    # `(*)` and the body raises, so the base states nothing about the arguments.
    def handle(*)
      raise NotImplementedError
    end
  end

  # A SECOND dispatcher, in no way related to the one above and spelling its
  # forward identically. `Example65Impostor` below is its subclass, and the two
  # hierarchies must not feed each other: if the receiver filter ever matched on
  # the method name alone, this one's `bool`/`Symbol` arguments would land on
  # `Example65Greeter#handle`, whose snapshot is the assertion.
  class Rival
    def self.dispatch(*args, **kwargs)
      handler = new
      handler.handle(*args, **kwargs)
      handler
    end

    def handle(*)
      raise NotImplementedError
    end
  end
end
