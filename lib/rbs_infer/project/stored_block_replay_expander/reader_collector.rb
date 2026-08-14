# frozen_string_literal: true

require "prism"

module RbsInfer::Project::StoredBlockReplayExpander
  # The `attr_reader :body` half of the chain, in its own lexical walk: `Collector`
  # can only resolve a relative `extend Builder` once every declaration in the file
  # is known, so reader recognition runs after that first pass rather than during it.
  #
  # Recognising the reader EXPLICITLY is the point — it is what keeps an arbitrary
  # method named `body` from being read as an ivar accessor.
  class ReaderCollector < Prism::Visitor
    attr_reader :readers

    def initialize
      @scope = []
      @method_depth = 0
      @readers = []
      super()
    end

    def visit_class_node(node) = with_scope(node) { super }
    def visit_module_node(node) = with_scope(node) { super }

    def visit_def_node(node)
      @method_depth += 1
      super
    ensure
      @method_depth -= 1
    end

    def visit_call_node(node)
      if @method_depth.zero? && node.name == :attr_reader && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) && node.arguments
        node.arguments.arguments.each do |argument|
          @readers << [@scope.last, argument.unescaped.to_s, "@#{argument.unescaped}"] if argument.is_a?(Prism::SymbolNode)
        end
      end
      super
    end

    private

    def with_scope(node)
      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return yield unless name

      name = name.sub(/\A::/, "")
      qualified = name.include?("::") ? name : [@scope.last, name].compact.join("::")
      @scope << qualified
      yield
    ensure
      @scope.pop if @scope.last == qualified
    end
  end
end
