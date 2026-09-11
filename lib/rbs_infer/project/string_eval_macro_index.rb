# frozen_string_literal: true

require "prism"
require_relative "parse_cache"
require_relative "string_eval_macro"

module RbsInfer::Project
  # The project's `class_eval`-a-string macros, by the name a call site spells.
  #
  # Built from the whole corpus rather than from the file being analysed,
  # because the two halves are never in one file: the macro ships in a gem (or
  # in the pseudo-code transcribed from one) and the call is written in a model.
  # That is the same asymmetry `StoredBlockReplayExpander` found in #265 — the
  # file that has to be rewritten is the one that mentions no eval at all.
  #
  # A name declared TWICE in the corpus is dropped rather than picked between.
  # A receiverless call names a method by its name alone, and which one it
  # reaches is a question of the ancestor chain — which for a gem's macro lives
  # in RBS, not in the Ruby this index reads. One candidate is an answer; two
  # is a guess, and a guess here writes methods onto a class that does not have
  # them.
  class StringEvalMacroIndex
    class << self
      # For a caller with no project to consult — a unit spec, or an entry point
      # handed a bare string. Named rather than defaulted, per
      # docs/engineering/required-threaded-deps.md: a caller that forgets to
      # thread the real one expands strictly less and says nothing about it,
      # which is the silent-wrong case.
      def none
        @none ||= new([])
      end
    end

    def initialize(source_files, parse_cache: nil)
      @macros = build(source_files, parse_cache)
    end

    # The macro a receiverless call of this name reaches, or nil.
    def [](name)
      @macros[name]
    end

    def any?
      !@macros.empty?
    end

    private

    def build(source_files, parse_cache)
      cache = parse_cache || ParseCache.new
      seen = {}

      source_files.each do |path|
        entry = cache.get(path) or next
        # The gate that keeps a project without this idiom from paying: the
        # file's own text, before anything reads its AST.
        next unless StringEvalMacro.possible?(entry.source)
        next unless entry.result.success?

        StringEvalMacro.macros_in(entry.result.value).each do |macro|
          # Second sighting of a name poisons it: `nil` is stored rather than
          # the entry deleted, so a THIRD file cannot resurrect it.
          seen[macro.name] = seen.key?(macro.name) ? nil : macro
        end
      end

      seen.compact
    end
  end
end
