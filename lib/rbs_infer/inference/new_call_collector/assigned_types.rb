# frozen_string_literal: true

class RbsInfer::Inference::NewCallCollector < Prism::Visitor
  # The types a class's or a method's own assignments state for its ivars and
  # locals (`@post = Post.new`, `dto = build_dto`), recorded into the
  # collector's scope before the body is visited.
  class AssignedTypes
    def initialize(method_return_types:, method_type_resolver:, caller_class_name:)
      @method_return_types = method_return_types
      @method_type_resolver = method_type_resolver
      @caller_class_name = caller_class_name
    end

    # Pré-coletar tipos de ivars de todos os métodos da classe
    # para que @post definido em set_post esteja disponível em publish.
    # Both `@x = Foo.new` and `@x, @y = Foo.new, Bar.new`
    # (felixefelip/rbs_infer#183).
    def from_class(class_node, into:)
      writes = RbsInfer::Analyzer.find_all_nodes(class_node) do |n|
        (n.is_a?(Prism::InstanceVariableWriteNode) && n.value.is_a?(Prism::CallNode)) ||
          n.is_a?(Prism::MultiWriteNode)
      end
      ivar_writes = writes.flat_map do |n|
        if n.is_a?(Prism::InstanceVariableWriteNode)
          [[n.name.to_s.sub(/\A@/, ""), n.value]]
        else
          RbsInfer::AST::MultiWriteDecomposer.ivar_name_pairs(n).select { |_, value| value.is_a?(Prism::CallNode) }
        end
      end

      ivar_writes.each { |var_name, call| record_call_type(var_name, call, into) unless into[var_name] }
    end

    def from_def(defn, into:)
      record_init_param_types(defn, into)

      body = defn.body or return
      statements = body.is_a?(Prism::StatementsNode) ? body.body : [body]
      statements.each do |stmt|
        case stmt
        when Prism::LocalVariableWriteNode
          record_local_type(stmt, into)
        when Prism::InstanceVariableWriteNode
          record_call_type(stmt.name.to_s.sub(/\A@/, ""), stmt.value, into)
        when Prism::MultiWriteNode
          RbsInfer::AST::MultiWriteDecomposer.ivar_name_pairs(stmt).each { |var_name, value| record_call_type(var_name, value, into) }
        end
      end
    end

    private

    def record_local_type(write, into)
      value = write.value
      unless value.is_a?(Prism::CallNode) && value.receiver.nil?
        return record_call_type(write.name.to_s, value, into)
      end

      return_type = @method_return_types[value.name.to_s]
      into[write.name.to_s] = return_type if return_type
    end

    def record_call_type(var_name, value, into)
      return unless value.is_a?(Prism::CallNode)

      class_name = RbsInfer::Analyzer.extract_constant_path(value.receiver) if value.receiver
      return unless class_name

      if value.name == :new
        into[var_name] = class_name
      elsif @method_type_resolver
        resolved = @method_type_resolver.resolve_class_method(class_name, value.name.to_s)
        into[var_name] = resolved.delete_suffix("?") if resolved && resolved != "untyped"
      end
    end

    # Resolver tipos dos parâmetros do método via call-sites do caller class
    # Ex: Entity#initialize(email:) → email é String (inferido dos call-sites de Entity.new)
    # Usa resolve_init_param_types (o que callers passam), NÃO resolve_all (tipos dos attrs)
    # Motivo: param email recebe String, mas attr email é Email (self.email = Email.new(...))
    # Só initialize por enquanto (caso mais comum e útil).
    def record_init_param_types(defn, into)
      return unless @method_type_resolver && @caller_class_name && defn.name == :initialize

      params = defn.parameters or return
      init_param_types = @method_type_resolver.resolve_init_param_types(@caller_class_name)
      (params.keywords + params.requireds).each do |param|
        next unless param.respond_to?(:name)

        type = init_param_types[param.name.to_s]
        into[param.name.to_s] = type if type && type != "untyped"
      end
    end
  end
end
