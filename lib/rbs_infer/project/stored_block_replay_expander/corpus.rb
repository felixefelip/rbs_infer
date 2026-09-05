# frozen_string_literal: true

require "set"

module RbsInfer::Project::StoredBlockReplayExpander
  # The walk from one file to the files it names but does not declare.
  #
  # A DSL chain is written across as many files as it takes: a host includes a
  # concern, the concern extends the module holding the DSL, and the DSL is
  # declared in a third file the host never mentions — `Post` / `Post::Taggable`
  # / `ActiveSupport::Concern`, which is the ordinary shape rather than an
  # exotic one. Reading one hop, the host saw the concern's shapes and nothing
  # about the DSL that gives the concern its methods (felixefelip/rbs_infer#268).
  #
  # A worklist rather than a recursion, `seen`-guarded because two concerns can
  # name each other. It terminates because a project has finitely many constants
  # and each is asked about once; in practice the chain is two or three files,
  # and every parse and walk along it is memoized by file.
  #
  # Split from `Collector` along the line between FINDING and KEEPING: which
  # file to open next, in what order, and once each, is this class; where the
  # shapes it hands back are stored is the collector's own business and stays
  # there (felixefelip/rbs_infer#305). The derivation is a block for the same
  # reason — the walk never learns what a shape collector is, so nothing here
  # knows how a file is read.
  class Corpus
    # `names` is every constant the walk resolved, which the caller records as
    # declared: reaching a name means this file's chain covers it. `shapes` is
    # what each file answered with, in the order reached.
    Reach = Data.define(:names, :shapes)

    def initialize(sources)
      @sources = sources
    end

    # Walks outward from `lookups`, deriving each file reached.
    #
    # `derive` answers `[shapes, lookups]` — what the file said, and what IT
    # looks for in turn. The second half is why the pair: a collector's own
    # lookups are `protected`, readable by another collector and by nothing
    # else, so the caller reads them and hands them over rather than this class
    # reaching in. It is also what keeps the walk ignorant of what a shape
    # collector is.
    #
    # The queue GROWS as it goes, which is what makes the chain transitive
    # rather than one hop deep.
    def reach(lookups, &derive)
      queue = lookups.to_a
      seen = Set.new
      found = []

      until queue.empty?
        name = resolve_lookup(queue.shift)
        next unless seen.add?(name)

        @sources.parsed_for(name).each do |entry|
          # Memoized per FILE, not per asking file: what a file says about its
          # own DSL is the same answer however many hosts ask, and a concern
          # used across an app is asked about by every one of them.
          shapes, onward = @sources.derived(entry) { derive.call(entry) }
          found << shapes
          queue.concat(onward.to_a)
        end
      end

      Reach.new(names: seen, shapes: found)
    end

    # The name a lookup lands on: the first candidate the project actually
    # declares, or — when it declares none of them — the name as written, which
    # is what this pass answered before it asked at all. Falling back rather
    # than dropping the lookup matters for the names a project never declares in
    # its own sources (`ApplicationRecord`, a gem's constant): they resolve to
    # themselves today and the chains reading them keep working.
    def resolve_lookup(candidates)
      candidates.find { |candidate| @sources.parsed_for(candidate).any? } || candidates.last
    end

    # The names Ruby tries for `name` written in `subject`, in order. Mirrors
    # `Collector#resolve_constant`'s walk exactly — every enclosing prefix,
    # longest first, then the name alone — so a lookup answered here resolves
    # there.
    #
    # A name is not a constant: `include Fields` inside `class Filter` reaches
    # `Filter::Fields` in one project and a top-level `Fields` in another, and
    # the difference is which one is declared. Reading the name as written, a
    # relatively-included concern named a constant nothing declares, so the
    # concern's file was never opened (felixefelip/rbs_infer#289).
    #
    # An explicitly absolute `::Foo` names the top level and nothing else, which
    # is the one-element list.
    #
    # A singleton method because it is a function of the two names and nothing
    # else — the collector asks it while BUILDING the lookups, before there is a
    # walk to ask.
    def self.lookup_candidates(name, subject)
      return [name.sub(/\A::/, "")] if name.start_with?("::")

      prefixes = subject.to_s.split("::")
      prefixes.length.downto(1).map { |length| "#{prefixes.take(length).join("::")}::#{name}" } + [name]
    end
  end
end
