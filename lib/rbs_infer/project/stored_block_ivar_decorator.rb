# frozen_string_literal: true

require_relative "block_body_type"

module RbsInfer::Project
  # Puts each stored block's source onto the slot that holds it, as the
  # `& ::RbsInfer::Body["…"]` half of the ivar's type
  # (felixefelip/rbs_infer#321).
  #
  # A CLASS where `BlockBodyType` is a module, for the reason that tells the two
  # apart everywhere else in this pass (see `DeferralReader`): this one has a
  # dependency. The bodies map is asked of it once per ivar group, and held it
  # appears in none of their signatures; `BlockBodyType` holds nothing and
  # renders a string from its arguments.
  #
  # The payload CARRIES the block; it does not ATTRIBUTE it. The declaration is
  # one line per module while the attribution is per call site, and `Example43`
  # is where the two come apart: `Baz` stores `def age` and `BazOther` stores
  # `def name` in the same `@_bazingado_block`, so the slot's type can only be a
  # union of both — while the relocation correctly gives `Bar` just `age` and
  # `BarOther2` both. The union is wrong at each end: it says "one of these" to
  # a class that got exactly one, and "one of these" to a class that got both.
  #
  # So nothing may read `Body[…]` off this declaration and conclude which block
  # a given host received — that answer comes from `Resolution`, per call site,
  # and RBS has no declaration site for a call.
  class StoredBlockIvarDecorator
    def initialize(bodies_by_owner)
      @bodies_by_owner = bodies_by_owner
    end

    # Rewrites both maps in place.
    #
    # Both, because a slot's owner decides which one it lands in: a storage
    # method written in the target class fills `ivar_types`, one written in a
    # nested module fills that module's entry in `module_ivar_types` — and the
    # DSL shape this exists for puts it in a module (`Example43::Foo`).
    def apply(ivar_types:, module_ivar_types:, target_class:)
      return if @bodies_by_owner.empty?

      module_ivar_types.each { |owner, ivars| decorate(ivars, bodies_for(owner)) }
      decorate(ivar_types, bodies_for(target_class))
    end

    private

    # The builder's ivar keys carry no `@`; a `Storage`'s do, since Prism's
    # `InstanceVariableWriteNode#name` is `:@x`.
    def decorate(ivars, bodies_by_ivar)
      return if bodies_by_ivar.nil? || bodies_by_ivar.empty?

      ivars.each_key do |name|
        bodies = bodies_by_ivar["@#{name}"]
        ivars[name] = BlockBodyType.decorate(ivars[name], bodies) if bodies
      end
    end

    # An owner written relatively in one map and fully qualified in the other is
    # the same owner: the builder keys a nested module by the name it declares
    # (`Foo`), while the collector's scope walk answers with the path
    # (`Example43::Foo`).
    def bodies_for(owner)
      return nil if owner.nil?

      key = @bodies_by_owner.keys.find { |candidate| candidate == owner || candidate.end_with?("::#{owner}") }
      key && @bodies_by_owner[key]
    end
  end
end
