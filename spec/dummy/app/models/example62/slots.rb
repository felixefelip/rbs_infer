# frozen_string_literal: true

# The slot the relocated block's `super` has to reach, written exactly as
# `IncludedHook::Slots` writes its own — an ivar behind a reader and a writer,
# in a file of its own, under a name nothing else in the dummy uses.
#
# All three are load-bearing rather than decoration, and each was measured:
#
#   * a method whose whole body is `nil` carries no type of its own, so its
#     signature is answered from elsewhere;
#   * a name shared with another model's method is where "elsewhere" comes from
#     — spelled `label`, this reader took `Account#label`'s `String` and Steep
#     then reported the body it actually has. `included_hook.rb` records the
#     same trap from the other side ("a slot with a UNIQUE name: `tag` was
#     borrowed from the dummy's Tag model closely enough to pick up a type from
#     elsewhere");
#   * a file of its own keeps it beside its sibling rather than nested in the
#     host's.
#
# `super || "shared"` over a `String?` slot is then the store-accessor shape the
# sibling fixture already pins, and `Example62Caller#read_hallmark` is `String`
# exactly when the def belongs to the host.
module Example62::Slots
  def hallmark
    @hallmark
  end

  def hallmark=(value)
    @hallmark = value
  end
end
