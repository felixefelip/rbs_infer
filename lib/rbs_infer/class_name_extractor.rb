module RbsInfer
  class Analyzer
  class ClassNameExtractor < Prism::Visitor
    attr_reader :class_name

    def initialize
      @namespace = []
      @class_name = nil
    end

    def visit_module_node(node)
      @namespace.push(extract_const_name(node.constant_path))
      super
      @namespace.pop
    end

    def visit_class_node(node)
      name = extract_const_name(node.constant_path)
      @class_name = (@namespace + [name]).join("::")
      @namespace.push(name)
      super
      @namespace.pop
    end

    private

    def extract_const_name(node)
      RbsInfer::Analyzer.extract_constant_path(node) || node.to_s
    end
  end
  end
end
