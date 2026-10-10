# frozen_string_literal: true

module RbsInfer::Inference
  # The classes below the target whose calls reach one of the target's own
  # methods (felixefelip/rbs_infer#412, #414):
  #
  #     class Base;           def call(name) = name; end
  #     class Kid < Base;     end                              # Kid.new runs Base#initialize
  #     class Other < Base;   def call(name) = super; end      # its super runs Base#call
  #
  # `reach(method_name)` answers with two sets:
  #
  # - `constructs`, for `initialize` only: the classes whose `new` runs the
  #   target's `initialize`, so `Kid.new(...)` is its call site.
  # - `supers`: the classes whose own `method_name` reaches the target's
  #   through `super`, so that `super` is.
  #
  # Which method runs is the RBS definition's answer, as everywhere else. The
  # source checks it: the RBS is the previous pass's output, so a class whose
  # source defines the method may not declare it yet, and then the RBS answers
  # with an ancestor's. Read as is, `Kid.new(3, :x)` would put `Integer` on
  # `Base`'s first parameter, and the next pass would keep it. A class on the
  # way whose source defines the method therefore takes the chain out,
  # whatever the RBS says.
  class InheritedReach
    Reach = Struct.new(:constructs, :supers)

    # For a collector whose usages are not `initialize`'s: nothing reaches it.
    NONE = Reach.new(Set.new.freeze, Set.new.freeze).freeze

    VISIBILITY_MODIFIERS = %i[private protected public].freeze

    # The instance `def`s written in a class body itself: each statement that
    # is one, or one under a modifier (`private def call`). Not one under
    # `class << self` or in a block, and not a `def self.`.
    def self.body_defs(class_node)
      statements = class_node.body
      return [] unless statements.is_a?(Prism::StatementsNode)

      statements.body.filter_map do |stmt|
        defn =
          if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && VISIBILITY_MODIFIERS.include?(stmt.name)
            arguments = stmt.arguments&.arguments || []
            arguments.first if arguments.size == 1
          else
            stmt
          end
        defn if defn.is_a?(Prism::DefNode) && defn.receiver.nil?
      end
    end

    # `source_index` and `parse_cache` read the subclasses' source, and the
    # resolver their RBS. None is defaulted: without them this silently answers
    # NONE (docs/engineering/required-threaded-deps.md).
    def initialize(target_class:, source_index:, parse_cache:, rbs_definition_resolver:)
      @target_class = target_class
      @source_index = source_index
      @parse_cache = parse_cache
      @resolver = rbs_definition_resolver
      @source_defs = {}
    end

    def reach(method_name)
      return NONE if parents.empty?

      method_name = method_name.to_s
      target = absolute(@target_class)
      constructs = Set.new
      supers = Set.new
      parents.each_key do |name|
        next if between(name, target).any? { |ancestor| source_defines?(ancestor, method_name) }

        if source_defines?(name, method_name)
          supers << relative(name) if @resolver.super_method_owner(name, method_name) == target
        elsif method_name == "initialize" && @resolver.method_owner(name, method_name) == target
          constructs << relative(name)
        end
      end
      Reach.new(constructs.freeze, supers.freeze)
    end

    # `{ "call" => Set["Kid"] }`: for each of `method_names`, the classes whose
    # `super` reaches the target's, leaving out the methods none reaches.
    def supers_by_method(method_names)
      return {} if parents.empty?

      method_names.each_with_object({}) do |method_name, acc|
        supers = reach(method_name).supers
        acc[method_name.to_s] = supers unless supers.empty?
      end
    end

    private

    def parents
      @parents ||= @resolver.descendant_parents(@target_class)
    end

    # The classes strictly between `name` and `target`.
    def between(name, target)
      chain = []
      current = parents[name]
      while current && current != target
        chain << current
        current = parents[current]
      end
      chain
    end

    # Whether the source defines `method_name` in the body of class `name`
    # itself.
    def source_defines?(name, method_name)
      source_defs(name).include?(method_name)
    end

    def source_defs(name)
      @source_defs.fetch(name) do
        fqn = relative(name)
        @source_defs[name] = @source_index.files_referencing(fqn).each_with_object(Set.new) do |file, defs|
          entry = @parse_cache.get(file) or next
          class_bodies(entry.result.value, fqn).each do |node|
            self.class.body_defs(node).each { |defn| defs << defn.name.to_s }
          end
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

    def absolute(name)
      name.start_with?("::") ? name : "::#{name}"
    end

    def relative(name)
      name.delete_prefix("::")
    end
  end
end
