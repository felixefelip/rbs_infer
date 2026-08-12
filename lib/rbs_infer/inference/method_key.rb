# frozen_string_literal: true

module RbsInfer
  module Inference
    # What identifies a method inside a target. The NAME does not.
    #
    # A target that hosts nested modules holds several methods at once that
    # share a name and are different methods: `Example23::Foo#bazingado` and
    # `Example23::Baz.bazingado` live in the same emitted `class Example23`
    # block, and a call site reaches exactly one of them. `TypeMerger` already
    # keys its member lookup on the triple (kind, name, owner) for that reason;
    # the inferred-parameter table did not, so a type read off one homonym's
    # call sites was written onto every homonym's signature
    # (felixefelip/rbs_infer#215).
    #
    # The key spells the triple the way RBS spells a method reference —
    # `Owner#name` for an instance method, `Owner.name` for a singleton — so a
    # qualified key can never collide with the bare name a target's OWN method
    # is filed under.
    module MethodKey
      # `owner` is the FULL owner path (`"Example23::Baz"`), or nil/empty for a
      # method the target itself declares, which keeps its bare name.
      def self.for(name, owner:, kind:)
        return name.to_s if owner.nil? || owner.to_s.empty?

        "#{owner}#{kind == :class_method ? "." : "#"}#{name}"
      end

      # What was inferred for this method's parameters.
      #
      # The bare entry is not an alternative to the qualified one, it is the
      # rest of the evidence: only an OWNER-matched call site knows enough to
      # qualify, so everything else about the same method — the intra-class
      # pass, a call site matched by name or by ancestry, a constant default
      # resolved later — is still filed under the bare name. Both are read, the
      # qualified one winning per parameter, and a method with no qualified
      # entry reads exactly what it always read.
      #
      # What this buys is the negative case: a homonym in a SIBLING module has
      # its types under its own key, so it no longer arrives here.
      def self.lookup(table, name, owner:, kind:)
        bare = table[name.to_s]
        key = self.for(name, owner: owner, kind: kind)
        return bare if key == name.to_s

        qualified = table[key]
        return bare if qualified.nil?
        return qualified if bare.nil?

        bare.merge(qualified)
      end

      # The entries that HOLD this method's parameter types, in `lookup`'s order
      # of precedence: the bare one first, the qualified one last.
      #
      # `lookup` answers a question — and when both entries exist it answers it
      # by MERGING them into a new hash. Writing into what it returns writes
      # into that copy, which is then dropped: the nil-default widening did
      # exactly this, so a parameter typed from an owner-matched call site kept
      # the type it had and the `= nil` in its own signature stopped being a
      # legal argument (felixefelip/rbs_infer#235). A write has to reach the
      # entry the value lives in, and which entry that is varies per parameter —
      # `base_foo` under the qualified key, `message` under the bare one.
      def self.tables(table, name, owner:, kind:)
        key = self.for(name, owner: owner, kind: kind)
        keys = key == name.to_s ? [name.to_s] : [name.to_s, key]

        keys.filter_map { |k| table[k] }
      end

      # `member.owner` is relative to the target (`"Baz"`); the table is keyed
      # by the full path.
      def self.qualify_owner(target_class, owner)
        return nil if owner.nil? || owner.to_s.empty?

        "#{target_class}::#{owner}"
      end
    end
  end
end
