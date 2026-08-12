require_relative "parse_cache"
require_relative "source_index"
require_relative "file_index"
require_relative "caller_file_cache"
require_relative "mixin_index"
require_relative "../inference/invoker_self_types"

module RbsInfer::Project
  # Everything about a project that a target class cannot change.
  #
  # `ParseCache`, `SourceIndex`, `FileIndex`, `CallerFileCache` and `MixinIndex`
  # are each a pure function of the source file list: which files exist, what
  # they parse to, which constants they name, what they `include`. Ask any of
  # them the same question while analysing `Card` or while analysing `User` and
  # the answer is identical — `CallerFileCache`'s own doc says as much ("results
  # are stable per file, independent of the target class").
  #
  # They were still built inside `Analyzer#initialize`, so a run over 91 targets
  # built 91 of each, and every one started cold: the corpus was re-read,
  # re-parsed and re-walked per target. On Fizzy that was `MixinIndex#build` at
  # 4.8% of wall time — 62% of it `ParseCache#get` — plus the allocation of ~91
  # copies of 812 Prism trees, which is what a 31% GC share is made of.
  #
  # Hoisting them here makes the work happen once. The analysis is unchanged:
  # every one of these was already shared across the whole of a single analysis,
  # so widening the scope to the run adds no sharing the pipeline did not
  # already assume — it only stops throwing the cache away between targets.
  #
  # Not cached here: anything that depends on generated RBS. `SteepEnvironment`
  # and `RbsTypeLookup` keep their own class-level caches precisely because the
  # CLI regenerates `sig/` between levels and passes and has to drop them
  # (`reset!`). Source `.rb` files do not change during a run, which is why
  # these five can outlive it.
  class Corpus
    class << self
      # One corpus per file list. The CLI hands the same array to every
      # `Analyzer`, so the identity check answers; `==` covers a caller that
      # rebuilt an equal list.
      def for(source_files)
        return @corpus if @corpus && (@key.equal?(source_files) || @key == source_files)

        @key = source_files
        @corpus = new(source_files)
      end

      # Drops the shared corpus. For tests and for a caller that changes the
      # files on disk mid-process — neither of which a single CLI run does.
      def reset!
        @corpus = nil
        @key = nil
      end
    end

    attr_reader :source_files, :parse_cache, :source_index, :file_index, :caller_file_cache

    def initialize(source_files)
      @source_files = source_files
      @parse_cache = ParseCache.new
      @source_index = SourceIndex.new(source_files)
      @file_index = FileIndex.new(source_files)
      @caller_file_cache = CallerFileCache.new(@parse_cache)
    end

    # Lazy, unlike the four above: an analysis that never asks about a mixin
    # should not pay for the walk, and `Analyzer` already treated it that way.
    def mixin_index
      @mixin_index ||= MixinIndex.new(@source_files, parse_cache: @parse_cache)
    end

    # Lazy for the same reason, and asked by little: only a module method with
    # more than one possible `self` ever narrows, and the answer is memoized per
    # method name for the whole run (felixefelip/rbs_infer#222). It sits here
    # rather than in `Analyzer` so the memo, like the four indexes above,
    # survives from one target to the next.
    def invoker_self_types
      @invoker_self_types ||= RbsInfer::Inference::InvokerSelfTypes.new(
        source_index: @source_index, parse_cache: @parse_cache
      )
    end
  end
end
