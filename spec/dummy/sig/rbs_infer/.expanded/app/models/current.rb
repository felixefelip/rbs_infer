# ⚠️  Gerado por rbs_infer para debug — NUNCA é carregado em runtime.
#     Visão expandida de app/models/current.rb (macros desaçucaradas em pseudo-código).
#     Regenerado a cada run; não edite.
# frozen_string_literal: true

# Fixture para felixefelip/rbs_infer#19: o tipo de `attribute :user` é
# inferido a partir dos call-sites de atribuição em outros arquivos
# (`Current.user = @post.user` no PostsController#publish e
# `Current.with(user: ...)` no ProfileFormatterJob), destravando o tipo
# do método derivado `self.author_full_name`.
class Current < ActiveSupport::CurrentAttributes
  def user; @user; end
  def user=(value); @user = value; end
  def self.user; @user; end
  def self.user=(value); @user = value; end
  def self.set(user: nil, &block); @user = user; block.call; end
  def self.with(user: nil, &block); @user = user; block.call; end

  # `&.` porque o atributo é honestamente nilável (reset per-request);
  # a inferência propaga o nil do safe-nav → `String?`.
  def self.author_full_name
    user&.full_name
  end
end
