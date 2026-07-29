class Example13
  # Byte-for-byte example3's memoized-singleton holder, which is what
  # `ActiveSupport::CurrentAttributes` amounts to: `Registry.user` is a constant
  # attribute with a nilable reader, reachable by the const-path machinery.
  #
  # Nested, like its example3 counterpart. It could not be until
  # felixefelip/steep#106: the guard's fact was written to the sidecar under the
  # SOURCE SPELLING (`Registry.user`) while the read resolved
  # `Example13::Registry.user`, so the two never met and the CONTROL failed for a
  # keying reason rather than a guard-grammar one. Now that both sides resolve,
  # this also stands as the regression guard for that fix.
  class Registry
    module GeneratedAttributes
      attr_accessor :user, :tenant
      attr_writer :registry_instance
    end

    include GeneratedAttributes

    def self.registry_instance
      @registry_instance ||= Registry.new
    end

    def self.user
      registry_instance.user
    end

    def self.user=(value)
      registry_instance.user = value
    end

    def self.tenant
      registry_instance.tenant
    end

    def self.tenant=(value)
      registry_instance.tenant = value
    end
  end

  # ---------------------------------------------------------------------------
  # Halting-guard grammar (felixefelip/steep#105). Every `guard_*` below is a
  # guard a human reads as "past this line the slot is populated" — the same
  # sentence `ApplicationController#authenticate_user` gets right. Each varies
  # ONE thing from that working shape, so the file reads as a bisection of what
  # the grammar accepts.
  #
  # Each pair is the runner shape the controller pseudo-code emits: `run_*` is
  # the flow (call the guard, check the halt, call the action) and `act_*` is the
  # action whose ENTRY the fact has to reach. The split is not cosmetic — entry
  # facts are attributed to the methods a flow calls after the halt check, not to
  # the remainder of the flow's own body.
  #
  # Every gap here is now CLOSED (felixefelip/steep#106 through #111), so the file
  # produces no errors at all and its whole job is to be the regression guard: the
  # baseline check fails on any NEW error, so a gap reopening surfaces as itself
  # rather than as a number going up. Each block below records what closed it, and
  # the `# should:` / `# actual:` markers are what flip if one comes back.
  # ---------------------------------------------------------------------------
  class Guarded
    def initialize(name:)
      @name = name
      @halted = false
    end

    def current_user
      Example13Viewer.find(@name)
    end

    def halt
      @halted = true
    end

    # A block-taking method that writes nothing itself — stands in for
    # `respond_to`, whose block is where the real halt sits.
    def with_format(&block)
      block&.call(:html)
    end

    # -------------------------------------------------------------------------
    # CONTROL. The shape the fork proves today: the condition is a bare
    # self-send, the aborting clause contains a literal `return`, and the fact
    # about the constant comes from a WRITE past the guard. Kept here so a
    # failure below is attributable to the one thing that varies, not to the
    # fixture harness.
    # -------------------------------------------------------------------------
    def guard_supported
      unless current_user
        halt
        return
      end

      Registry.user = current_user
    end

    def run_supported
      guard_supported
      return if @halted

      act_supported
    end

    def act_supported
      Registry.user.name.upcase # should: no error; actual: no error
    end

    # -------------------------------------------------------------------------
    # GAP 1 — CLOSED by felixefelip/steep#107. The guard TESTS the constant
    # instead of writing it.
    #
    # The only difference from the control is that the fact is read off the
    # condition rather than off a subsequent assignment. `presence_condition_
    # method` accepted only a bare self-send and returned a method NAME, so a
    # const-rooted receiver had nowhere to go — and `conditional_const_returns`
    # was populated exclusively from writes, so there was no path from a guard
    # that tests even in principle. The condition decoder now returns a list of
    # tagged facts.
    #
    # Testing is the far commoner shape: a guard normally asserts what someone
    # else already populated. It is the entire proof that `Current.user` is
    # non-nil in a real app's authorization layer.
    # -------------------------------------------------------------------------
    def guard_const_tested
      unless Registry.user
        halt
        return
      end
    end

    def run_const_tested
      guard_const_tested
      return if @halted

      act_const_tested
    end

    def act_const_tested
      Registry.user.name.upcase # should: no error; actual: no error
    end

    # -------------------------------------------------------------------------
    # GAP 1b — CLOSED by felixefelip/steep#108. Safe-navigation truthiness:
    # `&.` on nil yields nil, so a truthy `Registry.user&.active?` proves the
    # receiver non-nil EXACTLY, with no knowledge of what `active?` returns.
    #
    # Stating the fact as being about the RECEIVER is what made the arguments of
    # the safe-navigated call irrelevant, and what makes a chain (`a&.b&.c`)
    # prove its innermost nameable slot.
    # -------------------------------------------------------------------------
    def guard_safe_navigation
      unless Registry.user&.active?
        halt
        return
      end
    end

    def run_safe_navigation
      guard_safe_navigation
      return if @halted

      act_safe_navigation
    end

    def act_safe_navigation
      Registry.user.name.upcase # should: no error; actual: no error
    end

    # -------------------------------------------------------------------------
    # GAP 1c — CLOSED by felixefelip/steep#109. Conjunction: `A && B` is truthy
    # only if both are, so it proves everything either conjunct does. An
    # un-decodable conjunct is skipped rather than sinking the whole condition,
    # and `||` deliberately distributes to nothing — a truthy disjunction says
    # only that at least ONE operand was, with no way to tell which.
    #
    # The sharp edge is the `!` that turns `if !x` into "x is truthy here": it
    # belongs to the whole condition, and re-applying it per conjunct would make
    # `A && !B` claim `B` present when it is provably falsy.
    # -------------------------------------------------------------------------
    def guard_conjunction
      unless Registry.tenant && Registry.user
        halt
        return
      end
    end

    def run_conjunction
      guard_conjunction
      return if @halted

      act_conjunction
    end

    def act_conjunction
      Registry.user.name.upcase # should: no error; actual: no error
    end

    # -------------------------------------------------------------------------
    # GAP 2 — CLOSED by felixefelip/steep#111. No explicit `return`: the
    # condition is the CONTROL's bare self-send, and the only change is that the
    # guard is the method's last statement, so falling off the end is exactly a
    # return. `clause_returns?` walked for a `:return` node and found none.
    #
    # The rule stayed narrow on purpose — "the guard is the FINAL statement", not
    # "returns are optional". A halting clause with code after it does not end
    # the method; execution continues past the `if`, and proving anything there
    # would be a fact about a path that keeps going. That is the only place in
    # this grammar where being too permissive yields a WRONG proof rather than a
    # missing one, so the boundary is pinned on the fork side by a pair of tests:
    # the same clause proves nothing with a statement after it, and proves again
    # as soon as an explicit `return` is put back.
    #
    # Because the condition tests a SELF-METHOD, the failure also surfaced one
    # frame up, as a precondition contract error on the call to the action
    # (`requires `self.current_user` to be non-nil here`) — the checker naming
    # the exact fact the guard was supposed to supply.
    # -------------------------------------------------------------------------
    def guard_implicit_return
      unless current_user
        halt
      end
    end

    def run_implicit_return
      guard_implicit_return
      return if @halted

      act_implicit_return
    end

    def act_implicit_return
      current_user.name.upcase # should: no error; actual: no error
    end

    # -------------------------------------------------------------------------
    # GAP 3 — CLOSED by felixefelip/steep#110. The halt sits inside a block.
    # Also the CONTROL's condition, also with the literal `return`; only the halt
    # moved one block in.
    #
    # The guard WAS recognized — `walk_sends` has always handled block-nested
    # sends. What failed was naming the gate: `halting_gate` committed to the
    # FIRST bare self-send, here the block-taking `with_format`, which writes
    # nothing, so `Runner#resolve_gates!` found no ivar and dropped the spec.
    #
    # No position is reliably the halt: this shape puts it last, while
    # `redirect_to root_path` puts it first (the second send is an argument). So
    # the gate became a list of candidates in source order, resolved by the
    # Runner — which is the side that knows which of them writes what.
    #
    # Because the condition tests a SELF-METHOD, the failure also surfaced one
    # frame up, as a precondition contract error on the call to the action
    # (`requires `self.current_user` to be non-nil here`) — the checker naming
    # the exact fact the guard was supposed to supply.
    # -------------------------------------------------------------------------
    def guard_block_halt
      unless current_user
        with_format do |_format|
          halt
        end
        return
      end
    end

    def run_block_halt
      guard_block_halt
      return if @halted

      act_block_halt
    end

    def act_block_halt
      current_user.name.upcase # should: no error; actual: no error
    end

    # -------------------------------------------------------------------------
    # THE COMPOSITE — all four at once, which is how the shape actually occurs.
    # This is `Authorization#ensure_can_access_account` from a real app with the
    # framework names removed: a conjunction of const-rooted tests, one through
    # `&.`, halting inside a block, with no `return` because the guard is the
    # method's last statement.
    #
    # It was the last thing in this file to go green, and it needed every one of
    # the five fixes: it kept failing while any single gap remained open, which
    # is exactly why the file bisects them instead of leading with this.
    # -------------------------------------------------------------------------
    def guard_composite
      unless Registry.tenant && Registry.user&.active?
        with_format do |_format|
          halt
        end
      end
    end

    def run_composite
      guard_composite
      return if @halted

      act_composite
    end

    def act_composite
      Registry.user.name.upcase # should: no error; actual: no error
    end
  end

  # The call site. Pins `name` to `String` and — exactly as example3 does — makes
  # both `Registry` slots nilable by writing nil to them, so the
  # nilability comes from the code rather than from an annotation.
  def self.run
    Registry.tenant = Example13Tenant.new(label: 'acme')

    Registry.user = nil
    Registry.tenant = nil

    Guarded.new(name: 'John Doe').run_composite
  end
end

class Example13Viewer
  attr_reader :name

  def initialize(name:)
    @name = name
  end

  def active?
    true
  end

  # The nilable source. Mirrors the `find_by` a real app populates a
  # CurrentAttributes slot from — the reason the slot is nilable at all.
  def self.find(name)
    name.empty? ? nil : Example13Viewer.new(name: name)
  end
end

class Example13Tenant
  attr_reader :label

  def initialize(label:)
    @label = label
  end
end
