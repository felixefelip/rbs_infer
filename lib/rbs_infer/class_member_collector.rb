module RbsInfer
  class Analyzer
  # Estrutura que representa um membro da classe
  Member = Struct.new(:kind, :name, :signature, :visibility, keyword_init: true)

  class ClassMemberCollector < Prism::Visitor
    attr_reader :members, :superclass_name

    CONTROLLER_BASES = %w[ApplicationController ActionController::Base ActionController::API].freeze

    def initialize(comments:, lines:)
      @comments = comments
      @lines = lines
      @members = []
      @current_visibility = :public
      @is_controller = false
      @superclass_name = nil
    end

    def visit_class_node(node)
      if node.superclass
        @superclass_name = RbsInfer::Analyzer.extract_constant_path(node.superclass)
        @is_controller = CONTROLLER_BASES.include?(@superclass_name)
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

    def lines_between_are_blank_or_comments(lines, from_line, to_line)
      ((from_line)...(to_line - 1)).all? do |i|
        line = lines[i]
        next true if line.nil?
        stripped = line.strip
        stripped.empty? || stripped.start_with?("#")
      end
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
        type = infer_type_from_node(p.value) if p.respond_to?(:value)
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

      # Block
      if params.respond_to?(:block) && params.block
        parts << "?{ (untyped) -> untyped }"
      end

      "(#{parts.join(", ")})"
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

      infer_type_from_node(last_stmt)
    end

    AR_FINDER_METHODS = %i[find find_by find_by! first first! last last! take take! find_sole_by].freeze

    def infer_type_from_node(node)
      case node
      when Prism::CallNode
        if node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        elsif AR_FINDER_METHODS.include?(node.name) && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        end
      when Prism::StringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode then "Symbol"
      when Prism::TrueNode then "bool"
      when Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then "Hash[untyped, untyped]"
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        RbsInfer::Analyzer.extract_constant_path(node)
      when Prism::InstanceVariableWriteNode, Prism::LocalVariableWriteNode
        infer_type_from_node(node.value)
      end
    end
  end
  end
end
