# frozen_string_literal: true

module RbsInfer::Project
  # Reads a source file as Ruby, whatever its on-disk format.
  #
  # A `.erb` file is Ruby interleaved with text, so it is extracted first — the same way
  # `Steep::Source.parse` does it, keyed on the same suffix and using the same library.
  # This is FORMAT knowledge, not framework knowledge: ERB is not a Rails concept, and
  # nothing here looks at where the file lives or what class it belongs to (that is
  # `SourceOwners`, and it is an extension's business).
  #
  # One place, because there are two readers — `ParseCache` for the target and index, and
  # `CallerFileAnalyzer` for caller files, which reads on its own. Teaching only one of
  # them leaves ERB half-supported in a way that looks like a wiring bug.
  module SourceReader
    module_function

    # The file's Ruby, or nil when it cannot be read or extracted.
    def read(file)
      source = File.read(file)
      return source unless file.to_s.end_with?(".erb")

      extract_ruby(source)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def extract_ruby(source)
      require "herb"
      Herb.extract_ruby(source, comments: true)
    rescue LoadError, StandardError
      nil
    end
  end
end
