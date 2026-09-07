# frozen_string_literal: true

# A concern under a TOP-LEVEL namespace whose first segment a host also uses for
# a module of its own. Nothing here is special; the whole fixture is the name
# `Vault` — see `example64.rb`.
module Vault::Totaled
  extend ActiveSupport::Concern

  class_methods do
    def vault_key
      "vault"
    end
  end
end

module Vault::Totaled::ClassMethods
  # @type instance: singleton(::Example64) & ::Vault::Totaled::ClassMethods
  def vault_key
    "vault"
  end
end
