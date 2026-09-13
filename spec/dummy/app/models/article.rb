class Article < ApplicationRecord
  # The fixture for the ActionText generator, which writes exactly one file:
  # `has_rich_text` as ActionText wrote it. Nothing generates the accessors —
  # the macro defines them by `class_eval`ing a string, and the string is a
  # literal once this call site fixes `name`, so the checker folds it and
  # `Project::StringEvalMacroExpander` places what it folded HERE.
  has_rich_text :content

  # `store_if_blank: false` is the branch Rails writes a different writer body
  # for, and the call above takes the default it omits. Narrowing decides both,
  # so nothing in the tooling knows the option exists.
  has_rich_text :summary, store_if_blank: false
end
