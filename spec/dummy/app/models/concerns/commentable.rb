# frozen_string_literal: true

# felixefelip/rbs_infer#295. The association lives TWO hops from the model: a
# top-level concern shared by several models, re-exported by a per-model concern
# of the same name (`Post::Commentable` here) so each host can add its own hook.
# That is the ordinary Rails shape — it is where fizzy's `has_many :events`
# lives, in `Eventable` re-exported by `Card::Eventable`.
#
# The include that reaches this module is written ABSOLUTE (`include
# ::Commentable`), because inside `Post::Commentable` the bare name would be the
# enclosing module itself. Reading the two as the same name is what used to drop
# the splice: the walk from `Post::Commentable` offered `Post::Commentable` before
# `Commentable`, the includer resolved to itself, and the `has_many` never
# reached `Post` at all.
module Commentable
  extend ActiveSupport::Concern

  included do
    has_many :comments, dependent: :destroy
  end
end
