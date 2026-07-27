class Example12
  def run_name
    @name = 'John Doe'
    dispatch_name
  end

  def run_age
    @value = 42
    dispatch_age
  end

  # The ONE hop that example8 does not have. Each establishing method now calls
  # the dispatcher indirectly, so the body that writes the ivar and the body that
  # passes the literal are no longer the same.
  def dispatch_name
    show(:name)
  end

  def dispatch_age
    show(:age)
  end

  # SECOND-HOP gap in argument-sensitive facts (felixefelip/steep#93).
  # Byte-for-byte example8's dispatcher, and it used to narrow; here both reads
  # error.
  #
  # `infer_method_entry_facts` runs a call-graph fixpoint (felixefelip/steep#87)
  # that seeds each flow with its owner's entry facts, so a fact survives a hop.
  # `infer_argument_entry_facts` (felixefelip/steep#89, ivars in #91) has no such
  # seeding — it walks every flow with an EMPTY accumulator, on the assumption
  # that the establishing write and the dispatch sit in the same flow.
  #
  # They do in example8, and do not here. `dispatch_name`'s own body establishes
  # nothing, so its call site contributes `{}` to the `:name` partition; since a
  # partition is the MEET over its call sites, `{}` empties it. The partition
  # still FORMS — the parameter resolves, the literal is pinned, nothing is
  # unpinned — it is the meet that clears it.
  #
  # This is the controller shape, not a contrived one: a `before_action`
  # establishes `@post`, the action body calls `render :edit`, and the
  # establishment is one frame above the dispatch. It is why the view-runtime
  # switch (felixefelip/rbs_infer#109) left 9 residual errors that the retired
  # hand-rolled generator did not produce.
  #
  # Closing it needs the seeding AND ivars in `method_entry_facts`
  # (felixefelip/steep#92 item 4), which today carries only self-methods and
  # consts — so the seed would not transport `@name` even once it exists.
  def show(which)
    case which
    when :name
      @name.upcase # should: "JOHN DOE"; actual: error (second-hop gap)
    when :age
      @value.abs   # should: 42;         actual: error (second-hop gap)
    end
  end
end
