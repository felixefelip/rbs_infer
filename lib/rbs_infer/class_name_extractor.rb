module RbsInfer
  class ClassNameExtractor < Prism::Visitor
    attr_reader :class_name, :is_module

    def initialize
      @namespace = []
      @class_name = nil
      @is_module = false
    end

    def visit_module_node(node)
      name = extract_const_name(node.constant_path)
      unless @class_name
        @class_name = (@namespace + [name]).join("::")
        @is_module = true
      end
      @namespace.push(name)
      super
      @namespace.pop
    end

    def visit_class_node(node)
      name = extract_const_name(node.constant_path)
      if @class_name.nil? || @is_module
        @class_name = (@namespace + [name]).join("::")
        @is_module = false
      end
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
