module RbsInfer::Inference
  # Estrutura que representa um membro da classe.
  # `owner` = caminho do módulo aninhado que define o membro (ex.
  # "Formatting"), ou nil quando é membro direto da classe-alvo
  # (felixefelip/rbs_infer#22). Default nil preserva o comportamento atual.
  # `value_node` = nó Prism do RHS, preenchido só para membros `:constant`
  # (felixefelip/rbs_infer#37); o tipo é resolvido depois no Analyzer, que
  # tem acesso ao SteepBridge/resolvers, e gravado em `signature`.
  # `param_constant_defaults` = para membros `:method`/`:class_method`, mapa
  # `param => nó Prism` dos params opcionais cujo default é uma constante; o
  # tipo (valor da constante) também é resolvido depois no Analyzer (#46).
  # `old_name` = para membros `:alias`/`:singleton_alias`, o método original
  # apontado pelo alias; o RBS resolve o tipo nativamente via `alias`
  # (felixefelip/rbs_infer#63).
  # `singleton` = para membros `:attr_*`, se o attr foi declarado dentro de
  # `class << self` (attr de singleton, `self.attr x`). Distingue o attr de
  # instância `x` da class-instance variable `@x` escrita em `def self.x`, que
  # compartilham nome mas são slots diferentes (felixefelip/rbs_infer#86).
  # `block_arg_positions` = para membros `:method`/`:class_method`, onde ficam
  # os argumentos que o corpo passa para o bloco, um item por parâmetro do
  # bloco; o tipo de cada um vem do Steep, no Analyzer (#148).
  # `block_open_forward` = o corpo só repassa o bloco (`foo(&block)`), sem
  # chamá-lo nem testá-lo, então quem decide se ele é obrigatório é o callee —
  # também resolvido no Analyzer (#149).
  # `block_stored_forward` = o corpo GUARDA o bloco numa ivar (`@x = block`) em
  # vez de usá-lo, então quem decide contra qual `self` ele foi escrito é quem o
  # repassa depois — resolvido no Analyzer (#208).
  # `param_nil_defaults` = nomes dos params opcionais cujo default é o literal
  # `nil`. Enquanto o tipo é `untyped` não muda nada; quando os call-sites dão
  # um tipo de verdade ao param, é o que faz o `?` do nilable aparecer junto —
  # aplicado no Analyzer, onde o tipo inferido existe (#208).
  Member = Struct.new(:kind, :name, :signature, :visibility, :owner, :value_node, :param_constant_defaults, :old_name, :singleton, :block_arg_positions, :block_open_forward, :overloading, :param_nil_defaults, :block_stored_forward, keyword_init: true)

  # Metadata extraída de uma chamada `delegate` — tipos são resolvidos depois no Analyzer
  DelegateInfo = Struct.new(:methods, :target, :prefix, :allow_nil, keyword_init: true)

  # Pelo que eu entendi, essa classe é responsável por gerar o signature inicial
  # de uma class/module, porém depois no analyzer, terá outras classes que irão
  # refinar esse signature inicial, como por exemplo o `RbsInfer::Inference::ParamTypeInferrer`
  class ClassMemberCollector < Prism::Visitor
    include RbsInfer::AST::NodeTypeInferrer
    include RbsInfer::Signatures::RbsAnnotationParser
    include RbsInfer::AST::LexicalScope

    attr_reader :members, :delegates, :superclass_name, :is_module

    # Every module DECLARED inside the target, in source order, by the owner
    # path its members would carry. Kept apart from `members` because a
    # declaration is not a member: an empty one has nothing to be collected
    # from, and is still a module the RBS has to name.
    attr_reader :nested_modules

    # Structural collector: constant value/hash defaults are peeled off before
    # they reach the resolver path (bare constants → deferred to the Analyzer),
    # so this never types a value-position constant itself (felixefelip/rbs_infer#56).
    def constant_resolver = nil

    CONTROLLER_BASES = %w[ApplicationController ActionController::Base ActionController::API].freeze

    def initialize(comments:, lines:, target_class: nil)
      @comments = comments
      @lines = lines
      @members = []
      @nested_modules = []
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
        # A nested module is emitted from the OWNER its members carry, so one
        # with no members was emitted nowhere — a declaration the source makes
        # and the RBS does not, which is only invisible until something names
        # it (`include`, or a constant reference). Recorded here, where the
        # declaration is, rather than inferred from members that may not exist
        # (felixefelip/rbs_infer#268).
        @nested_modules << current_owner if current_owner
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

    # A block has its own execution context. Its `self` can be rebound by a
    # DSL, `class_eval`, or a stored proc replayed much later, so a definition
    # found there does not belong to the surrounding lexical class/module by
    # default. Contextual source expanders expose the statically known cases as
    # ordinary class/module reopenings before this collector runs (#238).
    #
    # Do not call `super`: besides defs, an arbitrary block can contain attrs,
    # includes and visibility calls that likewise must not leak to its lexical
    # owner. An explicit `class`/`module` declaration is different: it opens
    # its own structural scope, even when a framework runs that declaration in
    # a hook such as `to_prepare do`. Visit those direct declarations so their
    # members are collected from the declared owner, never from the block's
    # lexical owner. Control-flow nodes still use Prism's normal traversal.
    def visit_block_node(node)
      statements = node.body
      return unless statements.is_a?(Prism::StatementsNode)

      statements.body.each do |statement|
        statement.accept(self) if statement.is_a?(Prism::ClassNode) || statement.is_a?(Prism::ModuleNode)
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
      overloading = find_overloading_marker(@comments, @lines, node.location.start_line)

      extractor = ExtractParamsSignature.new(node.parameters, body: node.body)
      params_sig = extractor.call

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
        owner: current_owner,
        # Only when we synthesized the signature — an explicit `#:`/`@rbs`
        # annotation is authoritative and must not be overridden.
        param_constant_defaults: sig ? nil : extractor.constant_default_params,
        param_nil_defaults: sig ? nil : extractor.nil_default_params,
        block_arg_positions: sig ? nil : extractor.block_arg_positions,
        block_open_forward: sig ? nil : extractor.block_open_forward?,
        block_stored_forward: sig ? nil : extractor.block_stored_forward?,
        overloading: overloading
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
      when :prepend
        extract_includes(node, kind: :prepend)
      when :extend
        extract_extends(node)
      when :delegate
        extract_delegates(node)
      when :alias_method
        extract_alias_method(node)
      end

      super
    end

    # `alias new old` keyword (Prism::AliasMethodNode). Plain Ruby — same
    # native-`alias` emission path as `alias_method` (felixefelip/rbs_infer#63).
    def visit_alias_method_node(node)
      register_alias(node.new_name, node.old_name)
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

    # `kind:` distinguishes `include` from `prepend`. Both are mixins and are
    # collected identically; only the emitted keyword differs, and with it where
    # the module lands in the ancestor chain — which decides whose method a call
    # resolves to (felixefelip/rbs_infer#144).
    def extract_includes(node, kind: :include)
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
          kind: kind,
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

    # `alias_method :new, :old` (or string args). Registers an `:alias`
    # member; a non-literal name (dynamic alias) is skipped — no static
    # analysis can decide it (felixefelip/rbs_infer#63).
    def extract_alias_method(node)
      args = node.arguments&.arguments
      return unless args && args.length >= 2

      register_alias(args[0], args[1])
    end

    # Shared by `alias_method` and the `alias` keyword. Emits the alias into
    # the scope that owns it (concern module, singleton) so the RBS carries a
    # native `alias`, letting RBS/Steep resolve the original method's type.
    def register_alias(new_node, old_node)
      return unless inside_target?

      new_name = literal_method_name(new_node)
      old_name = literal_method_name(old_node)
      return unless new_name && old_name

      @members << Member.new(
        kind: in_singleton_self? ? :singleton_alias : :alias,
        name: new_name,
        old_name: old_name,
        signature: nil,
        visibility: @current_visibility,
        owner: current_owner
      )
    end

    # The method name a SymbolNode/StringNode literal denotes, or nil for a
    # dynamic (interpolated/computed) node.
    def literal_method_name(node)
      case node
      when Prism::SymbolNode, Prism::StringNode then node.unescaped
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
          owner: current_owner,
          # `class << self; attr_accessor :x` declares a singleton attr — its
          # `@x` is a class-instance variable, a slot distinct from an instance
          # attr of the same name (felixefelip/rbs_infer#86).
          singleton: in_singleton_self?
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

    # `# @rbs_infer |...` on its own line above a `def`: emit the signature as an
    # RBS *overloading* member (`def x: (...) -> T | ...`) rather than a plain one.
    #
    # It is what lets pseudo-code give a body to a method something else already
    # declares. Two declarations of one method in a class is a
    # `DuplicatedMethodDefinitionError` — which does not degrade, it poisons the whole
    # environment — while the overloading form adds the signature AHEAD of the existing
    # ones instead. Reopening `Module#include` to say what `include` does is the case
    # that needs it; `RBS::Environment` refuses the plain form outright.
    #
    # The marker states INTENT and is not trusted on its own: `| ...` requires a prior
    # definition, so claiming it where there is none is `InvalidOverloadMethodError`,
    # the same class of hard failure it exists to avoid. The analyzer confirms against
    # the environment before emitting (see `Analyzer#confirm_overloading!`).
    def find_overloading_marker(comments, lines, def_line)
      comments.any? do |comment|
        comment_line = comment.location.start_line
        next false unless comment_line.between?(def_line - 3, def_line - 1)
        next false unless lines_between_are_blank_or_comments(lines, comment_line, def_line)

        source_line = lines[comment_line - 1]
        if source_line
          code_before = source_line[0...comment.location.start_column].strip
          next false unless code_before.empty?
        end

        # `|...`, `| ...` and a trailing `...` alone all read as the same request.
        comment.location.slice.match?(/@rbs_infer\s+\|?\s*\.\.\./)
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

      # A bare constant as the last expression is a VALUE — a value constant
      # (`CONTINUE`, an `Integer`) or a class object (`User`, typed
      # `singleton(User)`) — never the bare name `infer_node_type` would yield,
      # which is invalid RBS for the former and wrong for the latter. Defer to
      # the Analyzer's Steep-backed return pass, which types both correctly
      # (felixefelip/rbs_infer#46).
      return nil if last_stmt.is_a?(Prism::ConstantReadNode) || last_stmt.is_a?(Prism::ConstantPathNode)

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
