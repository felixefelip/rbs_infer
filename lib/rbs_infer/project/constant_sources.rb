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
    NONE.freeze

    def initialize(source_index:, file_index:, parse_cache:)
      @source_index = source_index
      @file_index = file_index
      @parse_cache = parse_cache
      @parsed = {}
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
