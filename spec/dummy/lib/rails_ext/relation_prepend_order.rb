# The crossing the dummy had both halves of and never together
# (felixefelip/rbs_infer#340): a concern whose `included do` defines a METHOD,
# applied with `Receiver.include` rather than from a class body.
#
# Neither half is new. `included_hook.rb` replays a block's `def`s onto the host
# that includes the concern, and `array_conversions.rb` reopens a class the
# project does not declare by writing the `include` on the constant. Their
# crossing resolved nothing: the reopen carried the `include` and the module
# came out empty, so `prepend_order` was declared nowhere and every call site
# was a `NoMethod`.
#
# `Klass.include(Mod)` is not a stylistic choice here — it is the only spelling
# available. There is no `class ActiveRecord::Relation` in this project to write
# `include` inside, which is exactly why a `lib/rails_ext/` extension writes it
# this way, and why the two hosts below are one call each rather than one body.
#
# Copied in shape from fizzy's `lib/rails_ext/prepend_order.rb`, down to the two
# hosts: `AssociationRelation` is the second, so a fix that reads only the first
# call site is visible here.
module RelationPrependOrder
  extend ActiveSupport::Concern

  included do
    def prepend_order(*args)
      new_orders = args.flatten.map { |arg| arg.is_a?(String) ? arg : arg.to_sql }

      spawn.tap do |relation|
        relation.order_values = new_orders + order_values
      end
    end

    # A literal return, so the snapshot pins a TYPE and not only a method name:
    # a replay that lands but loses the body would still declare
    # `prepend_order` and would stop declaring this as `String`.
    def prepend_order_marker
      "prepend_order"
    end
  end
end

ActiveRecord::Relation.include(RelationPrependOrder)
ActiveRecord::AssociationRelation.include(RelationPrependOrder)
