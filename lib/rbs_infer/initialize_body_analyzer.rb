module RbsInfer
  class InitializeBodyAnalyzer < Prism::Visitor
    include NodeTypeInferrer

    attr_reader :self_assignments, :keyword_defaults

    def initialize
      @self_assignments = {}
      @keyword_defaults = {}
      @param_names = []
      @in_initialize = false
    end

    def visit_def_node(node)
      return super unless node.name == :initialize

      @in_initialize = true
      @param_names = extract_param_names(node.parameters)
      extract_keyword_defaults(node.parameters)
      super
      @in_initialize = false
    end

    def visit_call_node(node)
      if @in_initialize && node.name.to_s.end_with?("=") && node.receiver.is_a?(Prism::SelfNode)
        attr_name = node.name.to_s.chomp("=")
        value = node.arguments&.arguments&.first
        if value
          @self_assignments[attr_name] = resolve_assignment_value(value)
        end
      end
      super
    end

    def visit_instance_variable_write_node(node)
      if @in_initialize
        attr_name = node.name.to_s.sub(/\A@/, "")
        @self_assignments[attr_name] ||= resolve_assignment_value(node.value)
      end
      super
    end

    private

    def extract_param_names(params)
      return [] unless params
      names = []
      params.keywords.each do |kw|
        names << kw.name.to_s
      end if params.respond_to?(:keywords)
      params.requireds.each do |p|
        names << p.name.to_s if p.respond_to?(:name)
      end if params.respond_to?(:requireds)
      names
    end

    def extract_keyword_defaults(params)
      return unless params&.respond_to?(:keywords)

      params.keywords.each do |kw|
        next unless kw.is_a?(Prism::OptionalKeywordParameterNode)
        param_name = kw.name.to_s
        default_type = infer_type_from_node(kw.value)
        @keyword_defaults[param_name] = default_type if default_type
      end
    end

    def resolve_assignment_value(node)
      case node
      when Prism::LocalVariableReadNode
        name = node.name.to_s
        if @param_names.include?(name)
          { kind: :param, name: name }
        else
          { kind: :unknown }
        end
      when Prism::CallNode
        if node.receiver.is_a?(Prism::LocalVariableReadNode) && @param_names.include?(node.receiver.name.to_s)
          # aluno_dto.errors → tipo depende do tipo do param + método chamado
          { kind: :param_method, param_name: node.receiver.name.to_s, method_name: node.name.to_s }
        elsif node.name == :new && node.receiver
          class_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
          { kind: :constant, type: class_name }
        else
          class_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
          if class_name
            { kind: :call, type: class_name, class_name: class_name, method_name: node.name.to_s }
          else
            { kind: :unknown }
          end
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        { kind: :constant, type: RbsInfer::Analyzer.extract_constant_path(node) }
      when Prism::ArrayNode
        element_type = infer_collection_element_type(node.elements)
        { kind: :literal, type: "Array[#{element_type}]" }
      when Prism::HashNode
        key_type, value_type = infer_hash_types(node.elements)
        { kind: :literal, type: "Hash[#{key_type}, #{value_type}]" }
      else
        { kind: :unknown }
      end
    end

    def infer_type_from_node(node)
      # NilNode ignorado: default nil indica parâmetro opcional, não tipo nil
      return nil if node.is_a?(Prism::NilNode)
      infer_node_type(node)
    end

    def infer_collection_element_type(elements)
      return "untyped" if elements.empty?

      types = elements.filter_map { |el| infer_type_from_node(el) }.uniq
      return "untyped" if types.empty?

      types.join(" | ")
    end

    def infer_hash_types(elements)
      return ["untyped", "untyped"] if elements.empty?

      assocs = elements.select { |el| el.is_a?(Prism::AssocNode) }
      return ["untyped", "untyped"] if assocs.empty?

      key_types = assocs.filter_map { |a| infer_type_from_node(a.key) }.uniq
      value_types = assocs.filter_map { |a| infer_type_from_node(a.value) }.uniq

      key_type = key_types.empty? ? "untyped" : key_types.join(" | ")
      value_type = value_types.empty? ? "untyped" : value_types.join(" | ")

      [key_type, value_type]
    end
  end
end
