# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # Steep keys some facts by a site in the file it checked, so a source is
      # checked under its file's path only where it is that file's text, as
      # `steep check` reads it: an expanded view moves the sites.
      module CheckedPath
        UNFILED = Pathname("(rbs_infer)")

        def self.of(source_code, file)
          return UNFILED unless file && File.file?(file) && File.read(file) == source_code

          Pathname(File.expand_path(file))
        end
      end
    end
  end
end
