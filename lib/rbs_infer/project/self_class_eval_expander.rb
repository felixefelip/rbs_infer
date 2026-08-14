# frozen_string_literal: true

require "prism"
require_relative "source_expanders"
require_relative "virtual_reopen"

module RbsInfer::Project
  # Desugars `self.class.class_eval do … end` written inside an INSTANCE method
  # into a reopening of the class that method is defined in:
  #
  #   class Foo
  #     def build_age
  #       self.class.class_eval do
  #         def age; 25; end
  #       end
  #     end
  #   end
  #   # also reads as:
  #   class Foo
  #     def age; 25; end
  #   end
  #
  # `ClassEvalExpander` declines it, and its reason is right for the receiver it
  # names: `obj.class_eval` reopens whatever class the value happens to be, which
  # the call shape does not say. `self.class` inside an instance method DOES say
  # it — `self` is an instance of the enclosing class, so `self.class` is that
  # class, statically, with nothing to guess. Declining it left the methods in no
  # class at all, so a later call to one was reported as missing even where the
  # program had already defined it (felixefelip/rbs_infer#244).
  #
  # It cannot rewrite in place the way ClassEvalExpander does: the call sits in a
  # method body, where `class Foo … end` is a SyntaxError, not merely the wrong
  # scope. The body is emitted as a top-level reopening instead, through the
  # `VirtualReopen` the stored-block replay uses for the same reason.
  #
  # This is plain Ruby, not a framework convention, so it is CORE and registered
  # unconditionally, alongside ClassEvalExpander.
  #
  # WHEN the method runs is a separate question this does not answer: the
  # reopening says `age` is Foo's, not that it exists before `build_age` has been
  # called. A call that precedes it is a real NoMethodError that this makes the
  # checker stop reporting — see #245 for the marker that brings it back for the
  # right reason.
  module SelfClassEvalExpander
    REOPENING_METHODS = %i[class_eval module_eval].freeze

    module_function

    def expand(source)
      return nil unless REOPENING_METHODS.any? { |name| source.include?(name.to_s) }

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      collector = Collector.new
      parsed.value.accept(collector)
      return nil if collector.found.empty?

      reopens = collector.found.filter_map do |found|
        VirtualReopen.build(source: source, block: found.block, kind: found.kind, target: found.target)
      end
      return nil if reopens.empty?

      [source, reopens.join("\n")].join("\n")
    end

    # Finds the calls whose receiver is statically the enclosing class. It is a
    # lexical walk because that is what decides the answer: which class the
    # method is written in, and that `self` there is an instance of it.
    class Collector < Prism::Visitor
      Found = Data.define(:block, :kind, :target)

      attr_reader :found

      def initialize
        @scope = []
        @singleton_depth = 0
        @block_depth = 0
        # The scope depth of the instance method being visited, when that method
        # is written directly in a class body; nil otherwise.
        @instance_def_scope = nil
        @found = []
        super()
      end

      def visit_class_node(node) = with_scope(node, "class") { super }
      def visit_module_node(node) = with_scope(node, "module") { super }

      # `class << self` — a def inside is a SINGLETON method, where `self` is the
      # class and `self.class` is therefore `Class`, not the enclosing class.
      def visit_singleton_class_node(node)
        @singleton_depth += 1
        super
      ensure
        @singleton_depth -= 1
      end

      def visit_def_node(node)
        outer = @instance_def_scope
        @instance_def_scope = @scope.size if instance_method?(node) && @block_depth.zero?
        super
      ensure
        @instance_def_scope = outer
      end

      def visit_block_node(node)
        @block_depth += 1
        super
      ensure
        @block_depth -= 1
      end

      def visit_call_node(node)
        collect(node)
        super
      end

      private

      # `def x` in a class body. `def self.x` and anything inside `class << self`
      # are singleton methods, whose `self.class` is `Class`.
      def instance_method?(node)
        node.receiver.nil? && @singleton_depth.zero?
      end

      def collect(node)
        return unless REOPENING_METHODS.include?(node.name)
        return unless node.block.is_a?(Prism::BlockNode)
        return if node.arguments
        return unless self_class?(node.receiver)

        owner, kind = @scope.last
        return unless owner
        # Both the method and the call have to be written DIRECTLY in that
        # class's body and that method's body. Reached through any other block,
        # `self` is whatever yielded rebound it to, and the enclosing declaration
        # no longer says what `self.class` is — the same reason
        # ClassMemberCollector stopped attributing a block's defs to its lexical
        # owner (felixefelip/rbs_infer#238).
        return unless @instance_def_scope == @scope.size && @block_depth.zero?

        @found << Found.new(block: node.block, kind: kind, target: owner)
      end

      # `self.class`, and nothing else that spells a class: `self.class.new.class`
      # is another object's, and a local holding one says nothing here.
      def self_class?(node)
        node.is_a?(Prism::CallNode) && node.name == :class &&
          node.receiver.is_a?(Prism::SelfNode) && node.arguments.nil? && node.block.nil?
      end

      def with_scope(node, kind)
        name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
        return yield unless name

        name = name.sub(/\A::/, "")
        qualified = name.include?("::") ? name : [@scope.last&.first, name].compact.join("::")
        @scope.push([qualified, kind])
        yield
      ensure
        @scope.pop if @scope.last&.first == qualified
      end
    end
  end

  SourceExpanders.register(SelfClassEvalExpander)
end
