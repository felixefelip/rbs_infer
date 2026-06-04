# frozen_string_literal: true

# Fixture para felixefelip/rbs_infer#19: o tipo de `attribute :user` é
# inferido a partir dos call-sites de atribuição em outros arquivos
# (`Current.user = @post.user` no PostsController#publish e
# `Current.with(user: ...)` no ProfileFormatterJob), destravando o tipo
# do método derivado `self.author_full_name`.
class Current < ActiveSupport::CurrentAttributes
  attribute :user

  # `&.` porque o atributo é honestamente nilável (reset per-request);
  # a inferência propaga o nil do safe-nav → `String?`.
  def self.author_full_name
    user&.full_name
  end
end
