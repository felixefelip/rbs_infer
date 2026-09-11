class Article < ApplicationRecord
  # The fixture for the ActionText generator, which writes exactly one file:
  # `has_rich_text` as ActionText wrote it. Nothing generates the accessors —
  # the macro defines them by `class_eval`ing a string, and
  # `Project::StringEvalMacroExpander` renders that string HERE, where the call
  # site supplies the interpolation.
  has_rich_text :content

  # `store_if_blank: false` is the branch Rails writes a different writer body
  # for. The expander picks it by reading the macro's own `if` against this
  # call's keyword, so nothing in the tooling knows the option exists.
  has_rich_text :summary, store_if_blank: false
end
