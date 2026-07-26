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
      Example6::Foo.name.upcase # should: "JOHN DOE"; actual: error (else-branch gap)
    end
  end

  # BRANCH-SENSITIVE FLOW EXTRACTION gap ("peça (a)"). `Foo.name` is established
  # before the `if`, so it holds in BOTH branches; the `else` calls `greet` with
  # a non-nil `Foo.name`. But the fork's flow extractor walks only ONE clause of
  # a full `if/else` — `MethodEntryInferrer#call_target` returns the `then`
  # clause when it is non-empty — so the `else`-branch call `Bar.new.greet` is
  # never visited and `greet` never receives the entry fact. Its read is a
  # baselined error until the extractor descends into every branch (recording
  # each call with the branch-sensitive type `@typing` already computes).
  #
  # This is the exact shape of `render :new` sitting in the `else` of
  # `if @post.save` (felixefelip/rbs_infer#104): the per-controller `render`
  # override's dispatch stays inert until this same extraction lands.
  def run(condition)
    Example6::Foo.name = 'John Doe'

    if condition
      Example6::Foo.name.upcase # then branch: narrows within `run` today
    else
      Example6::Bar.new.greet # else branch: NOT walked -> greet errors (the gap)
    end
  end
end
