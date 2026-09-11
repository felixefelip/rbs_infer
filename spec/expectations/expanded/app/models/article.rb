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

class Article
  def content
    rich_text_content || build_rich_text_content
  end

  def content?
    rich_text_content.present?
  end

  def content=(body)
    self.content.body = body
  end

  def summary
    rich_text_summary || build_rich_text_summary
  end

  def summary?
    rich_text_summary.present?
  end

  def summary=(body)
    if body.present?
      self.summary.body = body
    else
      if summary?
        self.summary.body = body
        self.summary.mark_for_destruction
      end
    end
  end
end
