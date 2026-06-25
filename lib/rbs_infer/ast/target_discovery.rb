# frozen_string_literal: true

module RbsInfer::AST
  # Walks a (possibly macro-expanded) file tree and enumerates every
  # top-level type the file defines or reopens — the input to the
  # multi-target core (felixefelip/rbs_infer#38).
  #
  # Two kinds of target:
  #
  # - **declaration targets**: each `class`/`module` declared at
  #   class/module-nesting depth 0. Blocks (`on_load`, `to_prepare`, any
  #   `do ... end`) do NOT count as nesting, so a `module M` inside a
  #   `to_prepare` block is still depth 0. Declarations nested inside
  #   another class/module are left out — the owner mechanism in
  #   ClassMemberCollector/RbsBuilder already emits them in place.
  #
  # - **include targets**: `Receiver.include Mod` calls with an explicit
  #   constant receiver. These reopen `Receiver` to mix in `Mod`; there is
  #   no class body to analyze, so the core synthesizes a reopen block.
  class TargetDiscovery < Prism::Visitor
    attr_reader :declaration_targets, :include_targets

    def initialize
      @depth = 0
      @declaration_targets = []
      # receiver name => ordered, de-duplicated list of included module names
      @include_targets = {}
    end

    def visit_module_node(node)
      record_declaration(node, is_module: true)
      nest { super }
    end

    def visit_class_node(node)
      record_declaration(node, is_module: false)
      nest { super }
    end

    def visit_call_node(node)
      record_include_target(node) if node.name == :include
      super
    end

    private

    def nest
      @depth += 1
      yield
    ensure
      @depth -= 1
    end

    def record_declaration(node, is_module:)
      return unless @depth.zero?

      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return unless name && !name.empty?

      @declaration_targets << { name: name, is_module: is_module }
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
