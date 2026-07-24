class Example3
  class User
    attr_reader :name

    def initialize(name:)
      @name = name
    end
  end

  class Foo
    module GeneratedAttributes
      attr_accessor :user, :name
      attr_writer :foo_instance
    end

    include GeneratedAttributes

    def self.foo_instance
      @foo_instance ||= Foo.new
    end

    def self.user
      foo_instance.user
    end

    def self.user=(value)
      foo_instance.user = value
    end

    def self.name
      foo_instance.name
    end

    def self.name=(value)
      foo_instance.name = value
    end

    # Mutates the `user` slot to nil, but the caller only sees `Foo.clear_user`
    # (no `=`), so nothing tells the caller the slot was invalidated.
    def self.clear_user
      foo_instance.user = nil
    end

    def user=(value)
      super(value)

      self.name = value&.name
    end
  end

  def self.run
    user = User.new(name: 'John Doe')

    Foo.user = user

    Foo.user.name.upcase
    Foo.foo_instance.user.name.upcase
    Foo.foo_instance.name.upcase
    Foo.name.upcase # => "JOHN DOE"

    Foo.user = nil

    Foo.user.name.upcase # error not method
    Foo.foo_instance.user.name.upcase # error not method
    Foo.foo_instance.name.upcase # error not method
    Foo.name.upcase # error not method

    nil
  end

  # ---------------------------------------------------------------------------
  # Known const-narrowing gaps (companions to felixefelip/steep#83). Each is a
  # spelling that reaches the SAME slot Steep narrows for `Foo.user` /
  # `Foo.foo_instance.user`, but through a path the syntactic-path keying can't
  # tie back — so the narrowing is either unsound (a nil slips past) or
  # incomplete (a provably non-nil read is rejected). Marked SOUNDNESS GAP /
  # COMPLETENESS GAP; the `# should:` vs `# actual:` comments record today's
  # behavior and flip when the fork closes the gap.
  # ---------------------------------------------------------------------------

  # SOUNDNESS GAP — write through a local alias. `f` holds the same object as
  # `Foo.foo_instance`, but the write's receiver is a plain local, which
  # `memoized_singleton_accessor_base` doesn't recognize, so neither the fact
  # nor the pure-send cache for `Foo.user` is invalidated.
  def self.gap_alias_write
    u = User.new(name: 'x')
    Foo.user = u
    Foo.user.name.upcase # ok: narrowed here
    f = Foo.foo_instance
    f.user = nil
    Foo.user.name.upcase # should: error (nil); actual: NO error (stale non-nil)
  end

  # SOUNDNESS GAP — conditional write. The nil write invalidates on the `then`
  # path, but the branch join keeps the fact from the other path, so the read
  # after the `if` stays narrowed.
  def self.gap_conditional(cond)
    u = User.new(name: 'x')
    Foo.user = u
    Foo.user = nil if cond
    Foo.user.name.upcase # should: error (nil on a path); actual: NO error
  end

  # SOUNDNESS GAP — mutation hidden behind a method call. The caller sees
  # `Foo.clear_user` (no `=`), so the const-path write handling never fires and
  # there is no const-path analog to `apply_ivar_effects` to drop the fact.
  def self.gap_callee_mutation
    u = User.new(name: 'x')
    Foo.user = u
    Foo.clear_user
    Foo.user.name.upcase # should: error (nil); actual: NO error (stale non-nil)
  end

  # COMPLETENESS GAP — read through a local alias. Provably non-nil right after
  # the establishing write, but `g.user` is a third spelling the fact isn't
  # keyed under, so it is not narrowed. Conservative (a false positive), not
  # dangerous.
  def self.gap_alias_read
    u = User.new(name: 'x')
    Foo.user = u
    g = Foo.foo_instance
    g.user.name.upcase # should: no error (non-nil); actual: error (false positive)
  end
end
