# The call site, in a file that neither defines nor includes the concern: the
# only evidence `human_name`'s parameter has.
class Example59Labels
  INDEXES = %w[ all closed ]

  def labels
    INDEXES.map { |index| Example59.human_name(index) }
  end
end
