# frozen_string_literal: true

module RbsInfer::Project
  # The directory a project's sidecars hang off — `sig/generated/.steep_*.yml`
  # and the rest of what `steep check` writes.
  #
  # One rule, in one place, because two consumers already ask: `SteepBridge`
  # loads the contract/postcondition/callback/specialization stores from it, and
  # `Corpus` loads the string-eval sidecar. A run where those two disagree reads
  # half of what the checker wrote.
  module BaseDir
    module_function

    def current
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      else
        Dir.pwd
      end
    end
  end
end
