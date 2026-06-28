module RbsInfer::AST
  class DefCollector < Prism::Visitor
    include LexicalScope

    attr_reader :defs, :owners

    # `target_class` anchors owner computation; nil = no ownership (flat).
    def initialize(target_class: nil)
      @defs = []
      # def node => nested-module owner path (nil = direct class member),
      # so consumers correlating a def to a member can disambiguate names
      # that collide across a module and the class (e.g. an expanded
      # CurrentAttributes accessor and its override) — felixefelip#22.
      @owners = {}
      # def node => whether it defines a class (singleton) method, so
      # consumers match the same kind ClassMemberCollector assigned — an
      # instance and a singleton method sharing a name (`def consume` vs
      # `class << self; def consume`) are distinct members.
      @class_methods = {}
      self.scope_target = target_class
    end

    def visit_class_node(node)
      push_scope(:class, RbsInfer::Analyzer.extract_constant_path(node.constant_path))
      super
    ensure
      pop_scope
    end

    def visit_module_node(node)
      push_scope(:module, RbsInfer::Analyzer.extract_constant_path(node.constant_path))
      super
    ensure
      pop_scope
    end

    # `class << self` opens the enclosing class's singleton; push a
    # :singleton frame so `class_method_def?` sees nested defs as class
    # methods. `class << other` is a different object's singleton — leave it.
    def visit_singleton_class_node(node)
      singleton = node.expression.is_a?(Prism::SelfNode)
      push_scope(:singleton, nil) if singleton
      super
    ensure
      pop_scope if singleton
    end

    # `class_methods do ... end` (ActiveSupport::Concern) — open a
    # `module ClassMethods` owner so nested defs are attributed to it,
    # matching how ClassMemberCollector/RbsBuilder represent concern class
    # methods. Mirrors `visit_singleton_class_node` for `class << self`.
    def visit_call_node(node)
      is_class_methods = class_methods_block?(node)
      push_scope(:module, CLASS_METHODS_MODULE) if is_class_methods
      super
    ensure
      pop_scope if is_class_methods
    end

    def visit_def_node(node)
      @defs << node
      @owners[node] = current_owner
      @class_methods[node] = class_method_def?(node)
      super
    end

    # Owner of a previously-collected def node (nil = direct class member).
    def owner_of(node)
      @owners[node]
    end

    # Whether a previously-collected def node defines a class (singleton)
    # method — covers both `def self.x` and `class << self; def x`.
    def class_method?(node)
      @class_methods[node]
    end
  end
end
