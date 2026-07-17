# frozen_string_literal: true

module RbsInfer::AST
  # Walks a (possibly macro-expanded) file tree and enumerates every
  # top-level type the file defines or reopens — the input to the
  # multi-target core (felixefelip/rbs_infer#38).
  #
  # Two kinds of target:
  #
  # - **declaration targets**: every `class` the file declares, at any
  #   nesting depth, plus each `module` declared at class/module-nesting
  #   depth 0. Blocks (`on_load`, `to_prepare`, any `do ... end`) do NOT
  #   count as nesting, so a `module M` inside a `to_prepare` block is
  #   still depth 0. Nested names are fully qualified against their
  #   enclosing declarations (`class Example2; class User` → "Example2::User").
  #
  #   A nested *module* is excluded on purpose: the owner mechanism in
  #   ClassMemberCollector/RbsBuilder emits it in place, inside its
  #   enclosing target's block (felixefelip/rbs_infer#22). That mechanism
  #   only ever handled modules, so nested *classes* used to fall through
  #   it and have their members flattened into the enclosing class — see
  #   `namespace_wrapper?` and LexicalScope#inside_target?.
  #
  # - **include targets**: `Receiver.include Mod` calls with an explicit
  #   constant receiver. These reopen `Receiver` to mix in `Mod`; there is
  #   no class body to analyze, so the core synthesizes a reopen block.
  class TargetDiscovery < Prism::Visitor
    attr_reader :declaration_targets, :include_targets

    def initialize
      # Enclosing declaration names, outermost first — qualifies nested
      # targets. Blocks don't push, so it doubles as the depth counter.
      @namespace = []
      @declaration_targets = []
      # receiver name => ordered, de-duplicated list of included module names
      @include_targets = {}
    end

    def visit_module_node(node)
      record_declaration(node, is_module: true) if @namespace.empty?
      nest(node) { super }
    end

    def visit_class_node(node)
      record_declaration(node, is_module: false)
      nest(node) { super }
    end

    def visit_call_node(node)
      record_include_target(node) if node.name == :include
      super
    end

    private

    def nest(node)
      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return yield unless name && !name.empty?

      @namespace.push(name)
      yield
    ensure
      @namespace.pop if name && !name.empty?
    end

    def record_declaration(node, is_module:)
      return if namespace_wrapper?(node)

      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return unless name && !name.empty?

      @declaration_targets << { name: (@namespace + [name]).join("::"), is_module: is_module }
    end

    # A declaration whose body is nothing but other class/module declarations
    # (`module Admin; class User; ...; end; end`) is a pure namespace: it has
    # no members of its own to emit. RbsBuilder already re-declares every
    # enclosing namespace around each nested target, so making the wrapper a
    # target too would only add a redundant empty block next to the real one.
    #
    # An *empty* body is NOT a wrapper — `class A; end` declares a real (if
    # memberless) type and stays a target.
    def namespace_wrapper?(node)
      body = node.body
      return false if body.nil?

      stmts = body.body
      return false if stmts.empty?

      stmts.all? { |stmt| stmt.is_a?(Prism::ClassNode) || stmt.is_a?(Prism::ModuleNode) }
    end

    def record_include_target(node)
      receiver = node.receiver
      return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

      receiver_name = RbsInfer::Analyzer.extract_constant_path(receiver)
      return unless receiver_name && node.arguments

      modules = node.arguments.arguments.filter_map { |arg| RbsInfer::Analyzer.extract_constant_path(arg) }
      return if modules.empty?

      list = (@include_targets[receiver_name] ||= [])
      list.concat(modules)
      list.uniq!
    end
  end
end
