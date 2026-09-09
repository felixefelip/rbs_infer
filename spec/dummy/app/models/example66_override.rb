# The override half. It replaces `Example66Trackable#relevant?` from an
# `included do`, so the def belongs to the HOST — which is where fizzy's
# `Card::Mentions` puts `should_check_mentions?`, and it is what keeps the def
# out of the file `MethodTypeResolver` parses for `Example66`.
module Example66Override
  extend ActiveSupport::Concern

  included do
    def relevant?
      flagged?
    end
  end
end
