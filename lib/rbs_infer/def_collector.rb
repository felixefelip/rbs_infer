module RbsInfer
  class DefCollector < Prism::Visitor
    attr_reader :defs

    def initialize
      @defs = []
    end

    def visit_def_node(node)
      @defs << node
      super
    end
  end
end
