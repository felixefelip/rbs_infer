module RbsInfer::Inference
  class ClassBodyAttrAnalyzer < Prism::Visitor
    include RbsInfer::AST::NodeTypeInferrer

    attr_reader :attr_types, :collection_element_types, :constant_resolver

    # constant_resolver: env-aware resolver so an attr assigned a constant is
    # typed by the constant's VALUE, not its bare name (felixefelip/rbs_infer#56).
    #
    # target_class: the class whose attrs we're typing. The visitor walks the
    # whole parsed file (which may define several classes), so writes are only
    # counted while inside `target_class` — otherwise a local var or `self.x =`
    # in a *sibling* class whose name happens to match one of our attrs leaks
    # its type in (felixefelip/rbs_infer#38, mirroring the SteepBridge fix in
    # felixefelip/rbs_infer#69). Pass `nil` to opt out of scoping (whole file).
    def initialize(attr_names:, constant_resolver:, target_class:, method_type_resolver: nil)
      @attr_names = attr_names
      @constant_resolver = constant_resolver
      @target_class = target_class
      @namespace = []
      @attr_types = {}
      @collection_element_types = {}
      @in_method = false
      @method_type_resolver = method_type_resolver
    end

    def visit_class_node(node)
      with_namespace(node.constant_path) { super }
    end

    def visit_module_node(node)
      with_namespace(node.constant_path) { super }
    end

    def visit_def_node(node)
      @in_method = true
      @current_local_types = {}
      super
      # Após visitar o método, verificar variáveis locais que batem com attrs
      if in_target_class?
        @current_local_types.each do |name, type|
          if @attr_names.include?(name) && !@attr_types[name]
            @attr_types[name] = type
          end
        end
      end
      @in_method = false
    end

    def visit_call_node(node)
      if @in_method && in_target_class?
        # self.attr = Foo.new(...)
        if node.name.to_s.end_with?("=") && node.receiver.is_a?(Prism::SelfNode)
          attr_name = node.name.to_s.chomp("=")
          if @attr_names.include?(attr_name)
            value = node.arguments&.arguments&.first
            type = infer_type_from_node(value) if value
            @attr_types[attr_name] = type if type && !@attr_types[attr_name]
          end
        end

        # attr << Foo.new(...) / push / append / unshift / prepend / insert / concat
        collect_element_types_from_call(node)
      end
      super
    end

    def visit_local_variable_write_node(node)
      if @in_method && in_target_class?
        name = node.name.to_s
        if @attr_names.include?(name)
          type = infer_type_from_node(node.value)
          @current_local_types[name] = type if type
        end
      end
      super
    end

    def visit_instance_variable_write_node(node)
      if @in_method && in_target_class?
        name = node.name.to_s.sub(/\A@/, "")
        if @attr_names.include?(name) && !@attr_types[name]
          type = infer_type_from_node(node.value)
          @attr_types[name] = type if type
        end
      end
      super
    end

    # Métodos que adicionam elementos diretamente: todos os args são elementos
    ELEMENT_ADD_METHODS = %i[<< push append unshift prepend].to_set
    # insert: primeiro arg é índice, demais são elementos
    # concat: arg é um array, elementos estão dentro

    private

    # Pushes the class/module name (`Foo`, `Foo::Bar` for a compact path)
    # while visiting its body, so `in_target_class?` can tell whether the
    # current write belongs to the class we're generating for.
    def with_namespace(constant_path)
      name = RbsInfer::Analyzer.extract_constant_path(constant_path)
      @namespace.push(name) if name && !name.empty?
      yield
    ensure
      @namespace.pop if name && !name.empty?
    end

    # True when the current lexical class path is `target_class` or nested
    # under it (prefix match with a `::` boundary — so a nested-and-included
    # module writing the same ivars still counts, while `BoardMember` does
    # not match `Board`). A nil `target_class` disables scoping.
    def in_target_class?
      return true if @target_class.nil?

      current = @namespace.join("::")
      target = @target_class.to_s.sub(/\A::/, "")
      current == target || current.start_with?("#{target}::")
    end

    def collect_element_types_from_call(node)
      method_name = node.name
      return unless ELEMENT_ADD_METHODS.include?(method_name) || method_name == :insert || method_name == :concat

      attr_name = receiver_attr_name(node.receiver)
      return unless attr_name && @attr_names.include?(attr_name)

      args = node.arguments&.arguments
      return unless args&.any?

      types = case method_name
              when *ELEMENT_ADD_METHODS
                args.filter_map { |arg| infer_type_from_node(arg) }
              when :insert
                # primeiro arg é o índice, demais são elementos
                args[1..].filter_map { |arg| infer_type_from_node(arg) }
              when :concat
                # arg é um array literal — extrair tipos dos elementos internos
                args.flat_map do |arg|
                  if arg.is_a?(Prism::ArrayNode)
                    arg.elements.filter_map { |el| infer_type_from_node(el) }
                  else
                    []
                  end
                end
              end

      types&.each do |type|
        (@collection_element_types[attr_name] ||= Set.new) << type
      end
    end

    # Extracts the attr name from the receiver of a collection method call.
    # Handles: telefones << ... (implicit self) and self.telefones << ...
    def receiver_attr_name(receiver)
      case receiver
      when Prism::CallNode
        if receiver.receiver.nil? || receiver.receiver.is_a?(Prism::SelfNode)
          receiver.name.to_s
        end
      end
    end

    def infer_type_from_node(node)
      basic = infer_node_type(node)
      return basic if basic

      # Resolve class method calls: Klass.method → method_type_resolver
      if node.is_a?(Prism::CallNode) && node.receiver
        class_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
        if class_name
          if @method_type_resolver
            resolved = @method_type_resolver.resolve_class_method(class_name, node.name.to_s)
            return resolved if resolved && resolved != "untyped"
          end
          class_name
        end
      end
    end
  end
end
