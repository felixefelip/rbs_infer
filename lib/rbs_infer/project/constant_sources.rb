# frozen_string_literal: true

require "prism"

module RbsInfer::Project
  # Which of the project's files declare — or REOPEN — a given constant, as
  # parsed roots.
  #
  # `FileIndex` answers where a constant conventionally lives and `SourceIndex`
  # answers which files spell its name; neither answers "is the declaration
  # actually in there", and for a reopening of a core class the convention is
  # no guide at all — `class Module` can be written in any file. So both are
  # asked for candidates and every candidate is PARSED before it counts, the
  # same way `ClassMethodsIndex` walks `FileIndex#candidates` rather than
  # trusting the first hit (felixefelip/rbs_infer#185).
  #
  # Verification is what makes an over-broad candidate list harmless: a file
  # that merely mentions `Module` in a comment fails the walk and drops out.
  class ConstantSources
    # A null answer, for a caller that has no project to consult (a unit spec,
    # or an entry point handed a bare string). Named rather than defaulted: a
    # caller that forgets to thread the real one resolves strictly less and
    # says nothing about it, which is the silent-wrong case that
    # docs/engineering/required-threaded-deps.md is about.
    NONE = Object.new
    def NONE.parsed_for(_name) = []
    # No project to look in, so the file at hand is the whole world and its own
    # text is the complete answer to the two questions below.
    def NONE.eval_anywhere? = false
    def NONE.inward_extend_anywhere? = false
    def NONE.derived(_entry) = yield
    NONE.freeze

    # The calls whose block becomes a class body, which is the whole subject of
    # the pass that asks.
    BLOCK_EVALS = %w[class_eval module_eval].freeze

    # An `extend` written ON something, which is what a hook does to the object
    # it is handed (`base.extend(ClassMethods)`) — as against the bare
    # `extend Foo` of a class body, which nearly every project writes and which
    # says nothing about a hook.
    #
    # The leading dot is what tells the two apart, and it survives
    # `files_mentioning`'s word boundaries: `\b\.extend\b` requires a word
    # character immediately before the dot, which `base.extend` has and a line
    # starting `  extend Foo` does not.
    INWARD_EXTEND = ".extend"

    def initialize(source_index:, file_index:, parse_cache:)
      @source_index = source_index
      @file_index = file_index
      @parse_cache = parse_cache
      @parsed = {}
      # By IDENTITY, because the key is a parsed file and `ParseCache` hands
      # back the very same `Entry` for one path all run. Comparing Structs by
      # VALUE would hash the whole source string on every lookup, which is the
      # cost this memo exists to avoid.
      @derived = {}.compare_by_identity
    end

    # Every file declaring or reopening `name`, as `RbsInfer::ParsedFile` — the
    # tree AND the source, because a reader asking about a DSL needs both (an
    # `attr_reader` is read off the source, the method shapes off the tree).
    # Memoized per name: one constant is asked about once per file reaching for
    # it.
    def parsed_for(name)
      return [] if name.nil? || name.empty?

      @parsed[name] ||= candidates(name).filter_map do |file|
        entry = @parse_cache.get(file)
        entry if entry && declares?(entry.result.value, name)
      end
    end

    # A per-run memo for whatever a pass derives from one parsed file.
    #
    # The pass supplies the derivation; this only remembers it. A DSL declared
    # once and used from three hundred files is read three hundred times
    # otherwise — `parsed_for` already memoizes the PARSE, so what was repeated
    # was the walk over it, and that is the whole of the cost
    # (felixefelip/rbs_infer#265).
    #
    # Generic on purpose: naming the caller's shape here would put the replay
    # pass's vocabulary into an object whose subject is constants.
    def derived(entry)
      @derived.fetch(entry) { @derived[entry] = yield }
    end

    # Whether ANY file in the project writes a block eval.
    #
    # The precondition of the replay pass, and it has to be asked of the project
    # rather than of one file: a concern's `base.class_eval do … end` is written
    # where the concern is, and the `include` naming its target is written in
    # the host — which mentions no eval at all. Gating each file on its own text
    # is what made the host resolve nothing (felixefelip/rbs_infer#265).
    #
    # Kept because the property it protects is worth keeping: a project that
    # writes no eval anywhere can have no replay anywhere, so the pass costs it
    # one memoized scan and nothing else.
    #
    # `files_mentioning` rather than a scan of our own — it is the existing
    # "does the corpus say this anywhere" question, memoized per name and
    # deliberately over-approximating, which is the right direction here: a
    # false yes costs a walk, a false no loses a replay.
    def eval_anywhere?
      return @eval_anywhere if defined?(@eval_anywhere)

      @eval_anywhere = BLOCK_EVALS.any? { |name| @source_index.files_mentioning(name).any? }
    end

    # Whether any file writes an `extend` on a receiver — the same question as
    # `eval_anywhere?`, for the other thing a hook does with the object it is
    # handed (felixefelip/rbs_infer#268). Over-approximating in the same
    # direction, and for the same reason: a false yes costs a walk, a false no
    # loses the `extend`.
    #
    # Asked only when `eval_anywhere?` has already said no, so a project that
    # writes a block eval anywhere — every Rails app does, through the
    # transcribed `ActiveSupport::Concern` — never pays for this scan at all.
    def inward_extend_anywhere?
      return @inward_extend_anywhere if defined?(@inward_extend_anywhere)

      @inward_extend_anywhere = @source_index.files_mentioning(INWARD_EXTEND).any?
    end

    private

    def candidates(name)
      path = RbsInfer.class_name_to_path(name)
      (@file_index.candidates(path) + @source_index.files_referencing(name)).uniq
    end

    def declares?(root, name)
      finder = DeclarationFinder.new(name)
      root.accept(finder)
      finder.found?
    end

    # Finds `class <name>` or `module <name>` anywhere in a file, tracking
    # lexical nesting so `module A::B` and `module A; module B` both answer to
    # `A::B`.
    #
    # Either kind counts, unlike `ClassMethodsIndex::ModuleDeclarationFinder`
    # next door: that one is answering "can this be `extend`ed", where a class
    # would be the wrong answer. Here the question is only "does this file say
    # anything about that constant", and `class Module` — a class body defining
    # instance methods every class and module later calls — is precisely the
    # case that has to be found.
    class DeclarationFinder < Prism::Visitor
      def initialize(name)
        @name = name
        @namespace = []
        @found = false
      end

      def found? = @found

      def visit_class_node(node) = enter(node) { super }
      def visit_module_node(node) = enter(node) { super }

      private

      def enter(node)
        @namespace.push(RbsInfer::Analyzer.extract_constant_path(node.constant_path) || node.constant_path.to_s)
        @found = true if @namespace.join("::") == @name
        yield
        @namespace.pop
      end
    end
  end
end
