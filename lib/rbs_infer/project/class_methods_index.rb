# frozen_string_literal: true

require "prism"
require_relative "source_expanders"
require_relative "../ast/lexical_constant_resolver"

module RbsInfer::Project
  # Answers one question, for the `extend X::ClassMethods` that `RbsBuilder`
  # emits after an `include X`: does `X` define a nested `ClassMethods`?
  #
  # Two places can know, and both are consulted — a module's `ClassMethods` may
  # be declared in a gem's RBS (`.gem_rbs_collection/`) or, for a concern the
  # project itself defines, only in its own source. Looking at the gem
  # collection alone made every app-local concern answer "no": the
  # `module ClassMethods` was generated for the concern, the includer never got
  # the matching `extend`, and calls to those class methods came out
  # `Ruby::NoMethod` on the includer's singleton (felixefelip/rbs_infer#188).
  #
  # The source side reads the module's file through `SourceExpanders`, so a
  # concern whose class methods are written as a `class_methods do` block is
  # seen the same way a hand-written `module ClassMethods` is — this index
  # matches the plain nested module the expanders leave behind and stays
  # unaware of the DSL that produced it (docs/engineering/keep-core-framework-agnostic.md).
  #
  # The `X` of `include X` is written in `X`'s lexical scope, so candidates are
  # walked in Ruby's constant-lookup order: `include Params` inside `Filter`
  # asks about `Filter::Params` before top-level `Params`.
  class ClassMethodsIndex
    MODULE_NAME = "ClassMethods"

    # `file_index` and `parse_cache` are required: the sole production caller
    # (Analyzer) always has both, and an index built without them would answer
    # "no ClassMethods" for every project concern — silently reinstating the
    # very bug this exists to fix (docs/engineering/required-threaded-deps.md).
    def initialize(file_index:, parse_cache:)
      @file_index = file_index
      @parse_cache = parse_cache
      @answers = {}
      @roots = {}
    end

    # Whether `module_name`, as written inside `enclosing`, defines a nested
    # `module ClassMethods`.
    def has?(module_name, enclosing:)
      return false if module_name.nil? || module_name.empty?

      key = [module_name, enclosing]
      return @answers[key] if @answers.key?(key)

      @answers[key] = resolve(module_name, enclosing)
    end

    private

    def resolve(module_name, enclosing)
      candidates = RbsInfer::AST::LexicalConstantResolver.candidates(name: module_name, enclosing: enclosing)

      candidates.any? { |candidate| source_declares?(candidate) } ||
        candidates.any? { |candidate| gem_rbs_declares?(candidate) }
    end

    # Whether any file in the project declares `<full_name>::ClassMethods`.
    #
    # `FileIndex#candidates` matches by path SUFFIX, which is not unique, so
    # every candidate file is checked rather than just the first — the walk
    # compares the fully-qualified declared name, so a file that happens to
    # share a suffix simply fails to match (felixefelip/rbs_infer#185).
    def source_declares?(full_name)
      path = RbsInfer.class_name_to_path(full_name)

      @file_index.candidates(path).any? do |file|
        root = expanded_root(file)
        root && declares_module?(root, "#{full_name}::#{MODULE_NAME}")
      end
    end

    # The parsed root of `file` as the pipeline sees it — after the registered
    # expanders desugar their macros. Memoized per file: the same concern is
    # asked about once per class that includes it.
    def expanded_root(file)
      return @roots[file] if @roots.key?(file)

      @roots[file] = begin
        entry = @parse_cache.get(file)
        if entry.nil?
          nil
        elsif (expanded = RbsInfer::Project::SourceExpanders.apply(entry.source))
          result = Prism.parse(expanded)
          result.success? ? result.value : entry.result.value
        else
          entry.result.value
        end
      end
    end

    def declares_module?(root, qualified_name)
      finder = ModuleDeclarationFinder.new(qualified_name)
      root.accept(finder)
      finder.found?
    end

    # Whether a gem's RBS declares `<full_name>::ClassMethods`. This is the
    # original lookup, unchanged: a gem has no source in `source_files`, so its
    # checked-in RBS is the only thing that can answer.
    def gem_rbs_declares?(full_name)
      parts = full_name.split("::")
      first = parts.first

      gem_hints = [
        first.downcase,
        first.gsub(/([a-z])([A-Z])/, '\1_\2').downcase,
        first.gsub(/([a-z])([A-Z])/, '\1-\2').downcase,
      ].uniq

      rbs_files = gem_hints.flat_map { |hint| Dir[".gem_rbs_collection/#{hint}/**/*.rbs"] }.uniq
      return false if rbs_files.empty?

      rbs_files.any? do |file|
        content = File.read(file)
        content.include?(parts.last) &&
          RbsInfer::Signatures::RbsParserUtil.has_class_methods_submodule?(content, full_name)
      end
    end

    # Finds a `module <qualified_name>` declaration anywhere in a file,
    # tracking lexical nesting so `module Filter::Params; module ClassMethods`
    # and `module Filter; module Params; module ClassMethods` both resolve to
    # the same fully-qualified name.
    #
    # Only a `module` satisfies the match: `extend` takes a module, so a class
    # of that name would not be extendable and must not produce the mixin.
    class ModuleDeclarationFinder < Prism::Visitor
      def initialize(qualified_name)
        @qualified_name = qualified_name
        @namespace = []
        @found = false
      end

      def found? = @found

      def visit_module_node(node)
        enter(node) do
          @found = true if @namespace.join("::") == @qualified_name
          super
        end
      end

      # A class contributes its name to the nesting but can never BE the match.
      def visit_class_node(node)
        enter(node) { super }
      end

      private

      def enter(node)
        @namespace.push(const_name(node))
        yield
        @namespace.pop
      end

      def const_name(node)
        RbsInfer::Analyzer.extract_constant_path(node.constant_path) || node.constant_path.to_s
      end
    end
  end
end
