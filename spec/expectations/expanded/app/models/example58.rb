# A concern's instance method reaching the HOST's class methods through
# `self.class`.
#
# The concern is checked with its instance self type annotated as `Example58 &
# Example58::Defaults` — the shape every module self-type annotation takes,
# host first, module second. `Kernel#class` is baked per type into Steep's
# object shape, so both members carry their own answer for it, and the
# intersection's shape kept only the last member that defined the name:
# `self.class` came out `singleton(Example58::Defaults)`, which has none of
# the host's class methods, and `default_values` — the concern's own
# `class_methods do` block, extended into the host — was not there to call
# (felixefelip/steep#154).
#
# An intersection is inhabited by a value that satisfies EVERY member, so the
# shape now keeps every member's overloads; the two `class` overloads accept
# the same arguments, so they fold into one returning `singleton(Example58) &
# singleton(Example58::Defaults)`.
class Example58
  include Defaults

  # What the resolved call is worth: the record's value type reaches the host,
  # so `default_indexed_by` is `String` rather than `untyped`.
  def indexed_by
    default_indexed_by.upcase
  end
end

class Example58
  extend Example58::Defaults::ClassMethods
end
