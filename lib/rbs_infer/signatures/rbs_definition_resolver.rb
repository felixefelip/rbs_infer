module RbsInfer::Signatures
  # Resolve tipos via RBS DefinitionBuilder, com suporte a genéricos/type parameters.
  # Ex: Post.find(id) → Post (resolve ClassMethods[::Post, ...])
  # Ex: Post::ActiveRecord_Relation.last → Post? (resolve genéricos)
  #
  # Extraído de MethodTypeResolver para manter responsabilidades separadas.

  class RbsDefinitionResolver
    def initialize
      @rbs_builder = nil
      @rbs_builder_loaded = false
    end

    def resolve_via_rbs_builder(kind, class_name, method_name, block_body_type: nil)
      return nil unless rbs_builder

      # Intersection types (e.g. `(Order & Order::Validated)` yielded by
      # `Relation::Methods[Model, Pk, ValidatedModel]#each`) need to be split
      # before lookup — `RBS::TypeName` only accepts a single nominal name.
      # Resolve right-to-left to match
      # `Steep::Interface::Builder.intersection_shape`'s later-wins merge.
      if (components = parse_intersection_components(class_name))
        components.reverse_each do |component|
          result = resolve_via_rbs_builder(kind, component, method_name, block_body_type: block_body_type)
          return result if result && result != "untyped"
        end
        return nil
      end

      type_name = build_rbs_type_name(class_name)
      return nil unless type_name
      return nil unless rbs_builder.env.class_decls.key?(type_name)

      defn = case kind
             when :singleton then rbs_builder.build_singleton(type_name)
             when :instance then rbs_builder.build_instance(type_name)
             end

      method = defn&.methods&.[](method_name.to_sym)
      return nil unless method

      best = nil
      method.defs.each do |d|
        formatted = format_rbs_return_type(d.type.type.return_type, class_name)
        # For type variables (e.g. T in [T] { -> T } -> T), use the variable name
        # so it can be substituted by the type_params loop below
        if formatted.nil? && d.type.type.return_type.is_a?(RBS::Types::Variable) && d.type.type_params.any?
          formatted = d.type.type.return_type.name.to_s
        end
        next unless formatted
        if d.type.type_params.any?
          type_var_map = infer_type_vars_from_block(d.type, block_body_type: block_body_type)
          d.type.type_params.each do |tp|
            param_name = tp.respond_to?(:name) ? tp.name.to_s : tp.to_s
            replacement = type_var_map[param_name] || "untyped"
            formatted = formatted.gsub(/\b#{Regexp.escape(param_name)}\b/, replacement)
          end
        end
        return formatted unless formatted.include?("[self]")
        best ||= formatted
      end
      best
    rescue RBS::BaseError
      nil
    end

    # Resolve the element type of a collection by looking up the `each` method's
    # block parameter type via RBS definitions.
    # Works for any class with `each` defined in RBS (Array, Set, ActiveRecord_Relation, etc.)
    def resolve_each_element_type(collection_type)
      return nil unless rbs_builder

      type_name = build_rbs_type_name(collection_type)
      return nil unless type_name
      return nil unless rbs_builder.env.class_decls.key?(type_name)

      defn = rbs_builder.build_instance(type_name)
      each_method = defn&.methods&.[](:each)
      return nil unless each_method

      each_method.defs.each do |d|
        block = d.type.block
        next unless block

        first_param = block.type.required_positionals.first
        next unless first_param

        formatted = format_rbs_return_type(first_param.type, collection_type)
        return formatted if formatted && formatted != "untyped"
      end

      nil
    rescue RBS::BaseError
      nil
    end

    def format_rbs_return_type(rbs_type, context_class = nil)
      case rbs_type
      when RBS::Types::Bases::Instance
        context_class&.sub(/\A::/, "")
      when RBS::Types::Bases::Self
        "self"
      when RBS::Types::Bases::Bool
        "bool"
      when RBS::Types::Bases::Void
        "void"
      when RBS::Types::Bases::Nil
        "nil"
      when RBS::Types::Bases::Any
        "untyped"
      when RBS::Types::Variable
        nil
      else
        rbs_type.to_s.gsub(/(^|[\[\(, |])::/) { $1 }
      end
    end

    # Parses an intersection-type string via `RBS::Parser.parse_type` and
    # returns the component names. Returns nil for non-intersection (or
    # unparseable) strings so the caller takes the legacy fast path.
    def parse_intersection_components(class_name)
      parsed = RBS::Parser.parse_type(class_name)
      return nil unless parsed.is_a?(RBS::Types::Intersection)
      parsed.types.map(&:to_s)
    rescue RBS::ParsingError
      nil
    end

    # The RBS type-parameter list of an existing class/module, rendered as a
    # string ("[unchecked out Elem]"), or "" when it has none or is unknown.
    #
    # Reopening a generic class (e.g. `Array.include M` → `class Array ...`)
    # must repeat its EXACT params: RBS validates arity plus
    # variance/bounds/defaults after renaming, raising
    # GenericParameterMismatchError otherwise — which poisons the whole Steep
    # environment, not just the one file (felixefelip/rbs_infer#38). Emitting
    # the params verbatim from the primary declaration guarantees the match.
    def type_param_string(class_name)
      return "" unless rbs_builder

      type_name = build_rbs_type_name(class_name)
      return "" unless type_name

      entry = rbs_builder.env.class_decls[type_name]
      return "" unless entry

      params = entry.type_params
      return "" if params.empty?

      "[#{params.map(&:to_s).join(", ")}]"
    rescue StandardError
      # A lookup failure must never break generation — fall back to no params
      # (correct for the overwhelmingly common non-generic case).
      ""
    end

    private

    def rbs_builder
      return @rbs_builder if @rbs_builder_loaded
      @rbs_builder_loaded = true
      @rbs_builder = SteepBridge.definition_builder
    end

    # Infere variáveis de tipo genérico a partir da assinatura do bloco.
    # Ex: [U] { (Nokogiri::XML::Node) -> U } → { "U" => "Nokogiri::XML::Node" }
    # Se block_body_type for fornecido (tipo real do corpo do bloco), usa-o
    # em vez do tipo do parâmetro do bloco.
    def infer_type_vars_from_block(method_type, block_body_type: nil)
      block = method_type.block
      return {} unless block

      block_return = block.type.return_type
      return {} unless block_return.is_a?(RBS::Types::Variable)

      # Se temos o tipo real do corpo do bloco, usar ele
      if block_body_type && block_body_type != "untyped"
        return { block_return.name.to_s => block_body_type }
      end

      # Fallback: inferir a partir do tipo do parâmetro do bloco
      first_param = block.type.required_positionals.first
      return {} unless first_param

      param_type = format_rbs_return_type(first_param.type)
      return {} unless param_type && param_type != "untyped"

      { block_return.name.to_s => param_type }
    end

    def build_rbs_type_name(class_name)
      RBS::TypeName.parse(class_name).absolute!
    end
  end
end
