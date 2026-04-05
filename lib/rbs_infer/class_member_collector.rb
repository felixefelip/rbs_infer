module RbsInfer
  # Estrutura que representa um membro da classe
  Member = Struct.new(:kind, :name, :signature, :visibility, keyword_init: true)

  # Metadata extraída de uma chamada `delegate` — tipos são resolvidos depois no Analyzer
  DelegateInfo = Struct.new(:methods, :target, :prefix, :allow_nil, keyword_init: true)

  class ClassMemberCollector < Prism::Visitor
    include NodeTypeInferrer
    include RbsAnnotationParser

    attr_reader :members, :delegates, :superclass_name, :is_module

    CONTROLLER_BASES = %w[ApplicationController ActionController::Base ActionController::API].freeze

    def initialize(comments:, lines:)
      @comments = comments
      @lines = lines
      @members = []
      @delegates = []
      @current_visibility = :public
      @is_controller = false
      @superclass_name = nil
      @is_module = false
    end

    def visit_module_node(node)
      @is_module = true unless @superclass_name
      super
    end

    def visit_class_node(node)
      @is_module = false
      unless @primary_class_seen
        @primary_class_seen = true
        if node.superclass
          @superclass_name = RbsInfer::Analyzer.extract_constant_path(node.superclass)
          @is_controller = CONTROLLER_BASES.include?(@superclass_name)
        end
      end
      super
    end

    def visit_def_node(node)
      name = node.name.to_s
      sig = find_rbs_signature(@comments, @lines, node.location.start_line)

      # Extrair parâmetros do def para gerar assinatura básica se não tiver anotação
      params_sig = extract_params_signature(node)

      signature = if sig
                    "#{name}: #{sig}"
                  else
                    return_type = if @is_controller && @current_visibility == :public
                                   "void"
                                 else
                                   infer_return_type(node) || "untyped"
                                 end
                    "#{name}: #{params_sig} -> #{return_type}"
                  end

      @members << Member.new(
        kind: :method,
        name: name,
        signature: signature,
        visibility: @current_visibility
      )
      super
    end

    def visit_call_node(node)
      case node.name
      when :private
        if node.arguments.nil?
          # `private` sem args muda visibilidade padrão
          @current_visibility = :private
        end
      when :protected
        if node.arguments.nil?
          @current_visibility = :protected
        end
      when :public
        if node.arguments.nil?
          @current_visibility = :public
        end
      when :attr_accessor, :attr_reader, :attr_writer
        extract_attrs(node)
      when :include
        extract_includes(node)
      when :extend
        extract_extends(node)
      when :delegate
        extract_delegates(node)
      end

      super
    end

    private

    def extract_includes(node)
      return unless node.arguments

      node.arguments.arguments.each do |arg|
        name = RbsInfer::Analyzer.extract_constant_path(arg)
        next unless name

        @members << Member.new(
          kind: :include,
          name: name,
          signature: name,
          visibility: :public
        )
      end
    end

    def extract_extends(node)
      return unless node.arguments

      node.arguments.arguments.each do |arg|
        name = RbsInfer::Analyzer.extract_constant_path(arg)
        next unless name

        @members << Member.new(
          kind: :extend,
          name: name,
          signature: name,
          visibility: :public
        )
      end
    end

    def extract_delegates(node)
      return unless node.arguments

      args = node.arguments.arguments
      method_names = args.select { |a| a.is_a?(Prism::SymbolNode) }.map(&:value)
      return if method_names.empty?

      kwargs = args.find { |a| a.is_a?(Prism::KeywordHashNode) }
      return unless kwargs

      target = nil
      prefix = nil
      allow_nil = false

      kwargs.elements.each do |assoc|
        next unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)

        case assoc.key.value
        when "to"
          target = assoc.value.is_a?(Prism::SymbolNode) ? assoc.value.value : nil
        when "prefix"
          prefix = case assoc.value
                   when Prism::TrueNode then true
                   when Prism::SymbolNode then assoc.value.value
                   end
        when "allow_nil"
          allow_nil = assoc.value.is_a?(Prism::TrueNode)
        end
      end

      return unless target

      @delegates << DelegateInfo.new(
        methods: method_names,
        target: target,
        prefix: prefix,
        allow_nil: allow_nil
      )
    end

    def extract_attrs(node)
      return unless node.arguments

      # Buscar anotação inline na mesma linha: attr_accessor :foo #: Type
      attr_line = node.location.start_line
      inline_type = find_inline_type_same_line(@comments, attr_line)

      node.arguments.arguments.each do |arg|
        next unless arg.is_a?(Prism::SymbolNode)
        attr_name = arg.unescaped
        type = inline_type || "untyped"

        @members << Member.new(
          kind: node.name,
          name: attr_name,
          signature: "#{attr_name}: #{type}",
          visibility: @current_visibility
        )
      end
    end

    def find_inline_type_same_line(comments, line)
      comments.each do |comment|
        next unless comment.location.start_line == line
        text = comment.location.slice
        if text =~ /#:\s*(.+)/
          return $1.strip
        end
      end
      nil
    end

    def find_rbs_signature(comments, lines, def_line)
      # Buscar comentário rbs-inline acima do def (em sua própria linha dedicada)
      comments.each do |comment|
        comment_line = comment.location.start_line
        next unless comment_line.between?(def_line - 3, def_line - 1)
        next unless lines_between_are_blank_or_comments(lines, comment_line, def_line)

        # Ignorar comentários inline (na mesma linha de código, ex: attr_accessor :x #: Type)
        source_line = lines[comment_line - 1]
        if source_line
          code_before_comment = source_line[0...comment.location.start_column].strip
          next if !code_before_comment.empty?
        end

        text = comment.location.slice

        # #: (args) -> ReturnType  ou  #: -> ReturnType
        if text =~ /#:\s*(.+)/
          return $1.strip
        end

        # @rbs (args) -> ReturnType  (pular @rbs @ivar: que são anotações de ivar)
        if text =~ /@rbs\s+(@?)(.+)/
          next if $1 == "@"
          return $2.strip
        end
      end
      nil
    end

    def extract_params_signature(node)
      params = node.parameters
      return "()" unless params

      parts = []

      # Parâmetros posicionais obrigatórios
      params.requireds.each do |p|
        parts << param_name(p)
      end if params.respond_to?(:requireds)

      # Parâmetros opcionais
      params.optionals.each do |p|
        type = infer_node_type(p.value) if p.respond_to?(:value)
        parts << "?#{type || 'untyped'} #{p.name}"
      end if params.respond_to?(:optionals)

      # Rest param
      if params.respond_to?(:rest) && params.rest
        parts << "*untyped"
      end

      # Keywords obrigatórios
      params.keywords.each do |p|
        case p
        when Prism::RequiredKeywordParameterNode
          parts << "#{p.name}: untyped"
        when Prism::OptionalKeywordParameterNode
          parts << "?#{p.name}: untyped"
        end
      end if params.respond_to?(:keywords)

      # Keyword rest
      if params.respond_to?(:keyword_rest) && params.keyword_rest
        parts << "**untyped"
      end

      # Block — in RBS, the block goes after the closing paren, not inside it
      block_sig = nil
      if params.respond_to?(:block) && params.block
        block_sig = "?{ (untyped) -> untyped }"
      end

      result = "(#{parts.join(", ")})"
      result = "#{result} #{block_sig}" if block_sig
      result
    end

    def param_name(param)
      case param
      when Prism::RequiredParameterNode
        "untyped #{param.name}"
      else
        "untyped"
      end
    end

    def infer_return_type(defn)
      body = defn.body
      return nil unless body

      last_stmt = case body
                  when Prism::StatementsNode then body.body.last
                  else body
                  end

      return nil unless last_stmt

      type = infer_node_type(last_stmt)
      return nil unless type

      # Se há return nil no corpo, tornar nilable
      if has_nil_return?(defn) && !type.end_with?("?")
        type = "#{type}?"
      end

      type
    end

    def has_nil_return?(defn)
      RbsInfer::Analyzer.find_all_nodes(defn) do |node|
        next false unless node.is_a?(Prism::ReturnNode)
        node.arguments.nil? ||
          node.arguments.arguments.any? { |arg| arg.is_a?(Prism::NilNode) }
      end.any?
    end
  end
end
