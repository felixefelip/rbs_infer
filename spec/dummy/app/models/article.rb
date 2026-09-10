class Article < ApplicationRecord
  # The fixture for the ActionText runtime generator. `has_rich_text` writes
  # its accessors with `class_eval` on a heredoc string, so nothing static
  # reads them; the generated pseudo-code under
  # `sig/generated/steep_actiontext_runtime/` is what makes `article.content`
  # a method the checker can see.
  has_rich_text :content

  # `store_if_blank: false` is the branch Rails writes a DIFFERENT writer body
  # for — the generator picks it by reading the macro's own `if`, so this pins
  # that the branch is followed rather than assumed.
  has_rich_text :summary, store_if_blank: false
end
