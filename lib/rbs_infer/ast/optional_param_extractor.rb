module RbsInfer
  class OptionalParamExtractor < Prism::Visitor
    attr_reader :optional_params

    def initialize
      @optional_params = Set.new
    end

    def visit_def_node(node)
      return super unless node.name == :initialize
      params = node.parameters
      return unless params&.respond_to?(:keywords)

      params.keywords.each do |kw|
        if kw.is_a?(Prism::OptionalKeywordParameterNode)
          @optional_params.add(kw.name.to_s)
        end
      end

      params.optionals.each do |p|
        @optional_params.add(p.name.to_s) if p.respond_to?(:name)
      end if params.respond_to?(:optionals)
    end
  end
end
