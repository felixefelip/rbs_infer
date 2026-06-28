module RbsInfer::Inference
  # Estrutura que representa um membro da classe.
  # `owner` = caminho do módulo aninhado que define o membro (ex.
  # "Formatting"), ou nil quando é membro direto da classe-alvo
  # (felixefelip/rbs_infer#22). Default nil preserva o comportamento atual.
  # `value_node` = nó Prism do RHS, preenchido só para membros `:constant`
  # (felixefelip/rbs_infer#37); o tipo é resolvido depois no Analyzer, que
  # tem acesso ao SteepBridge/resolvers, e gravado em `signature`.
  Member = Struct.new(:kind, :name, :signature, :visibility, :owner, :value_node, keyword_init: true)

  # Metadata extraída de uma chamada `delegate` — tipos são resolvidos depois no Analyzer
  DelegateInfo = Struct.new(:methods, :target, :prefix, :allow_nil, keyword_init: true)

  class ClassMemberCollector < Prism::Visitor
    include RbsInfer::AST::NodeTypeInferrer
    include RbsInfer::Signatures::RbsAnnotationParser
    include RbsInfer::AST::LexicalScope

    attr_reader :members, :delegates, :superclass_name, :is_module

    CONTROLLER_BASES = %w[ApplicationController ActionController::Base ActionController::API].freeze

    def initialize(comments:, lines:, target_class: nil)
      @comments = comments
      @lines = lines
      @members = []
      @delegates = []
      @current_visibility = :public
      @is_controller = false
      @superclass_name = nil
      @is_module = false
      self.scope_target = target_class
    end

    # is_module/superclass/is_controller are read off the node that IS the
    # target — not the first declaration in the file. A multi-target file
    # reopens several classes/modules; keying on "first seen" would leak
    # one target's superclass onto another. `at_target?` (LexicalScope)
    # pins the capture to the matching frame. With no target set (the
    # collector used standalone), fall back to the legacy "first
    # declaration wins" behavior.
    def visit_module_node(node)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      with_scope(:module, segment) do
        @is_module = true unless @superclass_name if capture_metadata_here?
        super
      end
    end

    def visit_class_node(node)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      with_scope(:class, segment) do
        capture_class_metadata(node) if capture_metadata_here?
        super
      end
    end

    # When a target is set, only the matching frame contributes metadata
    # (multi-target correctness); otherwise every declaration does, so the
    # legacy first-wins guards below decide.
    def capture_metadata_here?
      scope_target ? at_target? : true
    end

    def capture_class_metadata(node)
      @is_module = false
      return if @primary_class_seen

      @primary_class_seen = true
      return unless node.superclass

      @superclass_name = RbsInfer::Analyzer.extract_constant_path(node.superclass)
      @is_controller = CONTROLLER_BASES.include?(@superclass_name)
    end

    # `class << self` — methods defined inside define singleton (class)
    # methods of the enclosing class, indistinguishable from instance defs
    # by node shape alone (no `self.` receiver). Push a :singleton scope so
    # `class_method_def?` classifies them correctly; reuse `with_scope` so a
    # `private` inside the block does not leak its visibility outward.
    # `class << other` opens another object's singleton (not this class's
    # methods), so leave its body untouched — same behavior as before.
    def visit_singleton_class_node(node)
      if node.expression.is_a?(Prism::SelfNode)
        with_scope(:singleton, nil) { super }
      else
        super
      end
    end

    def visit_def_node(node)
      # Only collect defs lexically inside the target. A def in a sibling
      # declaration or a bare block (e.g. `on_load do def x; end end` that
      # wasn't expanded) is not this target's method — attributing it here
      # is exactly the multi-target leak this gate closes.
      return super unless inside_target?

      is_class_method = class_method_def?(node)
      name = node.name.to_s
      sig = find_rbs_signature(@comments, @lines, node.location.start_line)

      params_sig = ExtractParamsSignature.new(node.parameters).call

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
        kind: is_class_method ? :class_method : :method,
        name: name,
        signature: signature,
        visibility: @current_visibility,
        owner: current_owner
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

    # `NAME = <expr>` — a class/module constant. The RHS type is inferred
    # later by the Analyzer (it owns the SteepBridge/resolvers); here we
    # only capture the name and the RHS node (felixefelip/rbs_infer#37).
    def visit_constant_write_node(node)
      collect_constant(node.name.to_s, node.value, namespace: :current)
      super
    end

    # `Foo::BAR = <expr>` / `self::BAR = <expr>`. We attribute it only when
    # the namespace is the scope we're generating — either `self`/the
    # current scope, or the fully-qualified target itself (which can appear
    # at top level, e.g. `Color::TOP = 1` outside `class Color`). A write
    # into some *other* namespace is that namespace's constant, not ours.
    def visit_constant_path_write_node(node)
      target = node.target
      ns = target.parent.is_a?(Prism::SelfNode) ? :current : RbsInfer::Analyzer.extract_constant_path(target.parent)
      collect_constant(target.name.to_s, node.value, namespace: ns)
      super
    end

    private

    # Records a `:constant` member when `namespace` places it in the scope
    # being generated. `:current` means the lexical scope (a plain `NAME =`
    # or `self::NAME =`); a string namespace is only ours when it equals the
    # fully-qualified target class.
    def collect_constant(name, value_node, namespace:)
      owner =
        case namespace
        when :current
          return unless within_target_scope?
          current_owner
        else
          # Qualified path write. Only `<target>::NAME = ...` is ours; it
          # names the class directly, so it's a direct member (owner nil)
          # and may legitimately sit at top level (no open scope needed).
          return unless namespace == scope_target&.sub(/\A::/, "")
          nil
        end

      @members << Member.new(
        kind: :constant,
        name: name,
        signature: nil,
        visibility: :public,
        owner: owner,
        value_node: value_node
      )
    end

    # True when the current lexical position is inside the class/module
    # being generated: directly in its body, or in a nested module of it.
    # Guards against collecting top-level constants (e.g. the `Color =
    # Struct.new(...)` that precedes a reopened `class Color`) and constants
    # of nested *classes* (which aren't members of the target) —
    # felixefelip/rbs_infer#37.
    def within_target_scope?
      return false if scope_stack.empty?

      target = scope_target&.sub(/\A::/, "")
      return true if target.nil? # flat mode (no target): innermost scope wins

      scope_stack.last[:path] == target || !current_owner.nil?
    end

    # Pushes a lexical scope frame, resetting visibility (a `private` in a
    # nested module must not leak out, and vice-versa), and restores both
    # on exit.
    def with_scope(kind, name)
      push_scope(kind, name)
      saved_visibility = @current_visibility
      @current_visibility = :public
      yield
    ensure
      @current_visibility = saved_visibility
      pop_scope
    end

    def extract_includes(node)
      # `Receiver.include Mod` (explicit constant receiver) reopens another
      # class — it is NOT a mixin of the current target. The multi-target
      # core picks these up as separate reopen targets (TargetDiscovery);
      # collecting them here would emit a bogus self-include. A `self.`
      # receiver is still the current target, so only skip real constants.
      return if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
      return unless inside_target?
      return unless node.arguments

      node.arguments.arguments.each do |arg|
        name = RbsInfer::Analyzer.extract_constant_path(arg)
        next unless name

        @members << Member.new(
          kind: :include,
          name: name,
          signature: name,
          visibility: :public,
          owner: current_owner
        )
      end
    end

    def extract_extends(node)
      return if node.receiver && !node.receiver.is_a?(Prism::SelfNode)
      return unless inside_target?
      return unless node.arguments

      node.arguments.arguments.each do |arg|
        name = RbsInfer::Analyzer.extract_constant_path(arg)
        next unless name

        @members << Member.new(
          kind: :extend,
          name: name,
          signature: name,
          visibility: :public,
          owner: current_owner
        )
      end
    end

    def extract_delegates(node)
      return unless inside_target?
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
      return unless inside_target?
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
          visibility: @current_visibility,
          owner: current_owner
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
      if has_nil_return?(defn)
        type = RbsInfer::Signatures::RbsParserUtil.nilablize(type)
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
