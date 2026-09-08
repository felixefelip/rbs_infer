# frozen_string_literal: true

# The shadow. A module of the host's own, nested under it, sharing its name with
# the ROOT of the concern's namespace — which is the whole point of the fixture
# (see `example64.rb`). It does nothing else.
module Example64::Vault
  def self.label
    "nested"
  end
end
