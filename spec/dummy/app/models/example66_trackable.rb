# The contract half of the override gap (see `example66.rb`).
#
# `relevant?` is a template method: the module states an answer (`false`, so
# `bool`) that a host is free to replace. `flag` is written only from `mark!` —
# never at construction — so the accessor is `bool?`, and reading it through the
# alias is what makes an override's body a DIFFERENT type from the contract.
#
# Read off fizzy: `Mentions#should_check_mentions?` (the template) and
# `Card::Statuses#was_just_published` (the accessor written only from a
# `before_save`, reached through `alias_method :was_just_published?`).
module Example66Trackable
  attr_accessor :flag
  alias_method :flagged?, :flag

  def mark!
    self.flag = true
  end

  def relevant?
    false
  end
end
