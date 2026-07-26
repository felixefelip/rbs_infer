class Example6
  class Foo
    def self.name
      @name
    end

    def self.name=(value)
      @name = value
    end
  end

  class Bar
    # Reached only from the `else` branch of `run`, where `Foo.name` is already
    # established — so a human reading the source sees this read as non-nil.
    def greet
      Example6::Foo.name.upcase # => "JOHN DOE" (else-branch call now carries the fact)
    end
  end

  # BRANCH-SENSITIVE FLOW EXTRACTION ("peça (a)"). `Foo.name` is established
  # before the `if`, so it holds in BOTH branches; the `else` calls `greet` with
  # a non-nil `Foo.name`. The fork's flow extractor used to walk only ONE clause
  # of a full `if/else` — `MethodEntryInferrer#call_target` returned the `then`
  # clause when non-empty — so the `else`-branch call `Bar.new.greet` was never
  # visited and `greet` never received the entry fact. Now the extractor descends
  # into EVERY branch of a full `if/else` (and every `case/when`), recording each
  # call with the branch-sensitive type `@typing` already computes, so `greet`
  # narrows here just as the `then`-branch read does.
  #
  # This is the exact shape of `render :new` sitting in the `else` of
  # `if @post.save` (felixefelip/rbs_infer#104): the per-controller `render`
  # override's dispatch was inert until this extraction landed — now both the
  # `then` and `else` render targets propagate their entry facts to the view.
  def run(condition)
    Example6::Foo.name = 'John Doe'

    if condition
      Example6::Foo.name.upcase # then branch: narrows within `run`
    else
      Example6::Bar.new.greet # else branch: now walked -> greet carries the fact
    end
  end
end
