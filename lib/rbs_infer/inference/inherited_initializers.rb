# frozen_string_literal: true

module RbsInfer::Inference
  # The classes whose `initialize` call reaches the target's `initialize`
  # (felixefelip/rbs_infer#412):
  #
  #     class Base;               def initialize(name) = @name = name; end
  #     class Kid < Base;         end                                   # Kid.new runs Base#initialize
  #     class Other < Base;       def initialize(name) = super; end     # its super does
  #
  # `constructs` are the classes whose `new` runs the target's `initialize`,
  # so `Kid.new(...)` is its call site; `supers` are the classes whose own
  # `initialize` reaches it through `super`, so that `super` is.
  #
  # Which `initialize` runs is the RBS definition's answer, as everywhere
  # else. The source checks it: the RBS is the previous pass's output, so a
  # class whose source defines `initialize` may not declare it yet, and then
  # the RBS answers with an ancestor's. Read as is, `Kid.new(3, :x)` would put
  # `Integer` on `Base`'s first parameter and the next pass would keep it. A
  # class on the way whose source defines `initialize` therefore takes the
  # chain out, whatever the RBS says.
  class InheritedInitializers
    Reach = Struct.new(:constructs, :supers)

    # For a collector whose usages are not `initialize`'s: nothing reaches it.
    NONE = Reach.new(Set.new.freeze, Set.new.freeze).freeze

    # `source_index` and `parse_cache` read the subclasses' source, and the
    # resolver their RBS. None is defaulted: without them this silently answers
    # NONE (docs/engineering/required-threaded-deps.md).
    def initialize(target_class:, source_index:, parse_cache:, rbs_definition_resolver:)
      @target_class = target_class
      @source_index = source_index
      @parse_cache = parse_cache
      @resolver = rbs_definition_resolver
      @source_initializers = {}
    end

    def reach
      parents = @resolver.descendant_parents(@target_class)
      return NONE if parents.empty?

      target = absolute(@target_class)
      constructs = Set.new
      supers = Set.new
      parents.each_key do |name|
        next if between(name, target, parents).any? { |ancestor| source_initializer?(ancestor) }

        if !source_initializer?(name) && @resolver.method_owner(name, "initialize") == target
          constructs << relative(name)
        elsif source_initializer?(name) && @resolver.super_method_owner(name, "initialize") == target
          supers << relative(name)
        end
      end
      Reach.new(constructs.freeze, supers.freeze)
    end

    private

    # The classes strictly between `name` and `target`.
    def between(name, target, parents)
      chain = []
      current = parents[name]
      while current && current != target
        chain << current
        current = parents[current]
      end
      chain
    end

    # Whether the source defines `initialize` in the body of class `name`
    # itself: not under `class << self`, not in a block.
    def source_initializer?(name)
      @source_initializers.fetch(name) do
        fqn = relative(name)
        @source_initializers[name] = @source_index.files_referencing(fqn).any? do |file|
          entry = @parse_cache.get(file) or next false
          class_bodies(entry.result.value, fqn).any? { |node| direct_initialize?(node) }
        end
      end
    end

    def class_bodies(root, fqn, outer = nil, found = [])
      return found unless root.is_a?(Prism::Node)

      if root.is_a?(Prism::ClassNode) || root.is_a?(Prism::ModuleNode)
        segment = RbsInfer::Analyzer.extract_constant_path(root.constant_path)
        if segment
          outer = outer ? "#{outer}::#{segment}" : segment
          found << root if root.is_a?(Prism::ClassNode) && (outer == fqn || segment == fqn)
        end
      end
      root.compact_child_nodes.each { |child| class_bodies(child, fqn, outer, found) }
      found
    end

    def direct_initialize?(class_node)
      statements = class_node.body
      return false unless statements.is_a?(Prism::StatementsNode)

      statements.body.any? { |stmt| stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && stmt.name == :initialize }
    end

    def absolute(name)
      name.start_with?("::") ? name : "::#{name}"
    end

    def relative(name)
      name.delete_prefix("::")
    end
  end
end
