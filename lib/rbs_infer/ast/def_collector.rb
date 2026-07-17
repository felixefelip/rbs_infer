module RbsInfer::AST
  class DefCollector < Prism::Visitor
    include LexicalScope

    attr_reader :defs, :owners

    # `target_class` scopes collection to that class's own defs and anchors
    # owner computation. It stays defaulted rather than required (cf.
    # docs/engineering/required-threaded-deps.md) because the caller-file
    # consumers — CallerFileAnalyzer, CallerFileCache, MethodTypeResolver —
    # legitimately walk a file with no target at all, and for them flat IS
    # the correct behavior. Anything walking the *target* file must pass it:
    # omitting it there collects nested classes' defs too (silent-wrong).
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

    def visit_def_node(node)
      # With a target set, only that target's defs are collected. A def in a
      # nested class belongs to that class's own target (TargetDiscovery
      # promotes every class), and its owner is nil — indistinguishable from
      # a direct member — so consumers that don't cross-check against the
      # member list would silently attribute it here: `@name = name` in
      # `Example3::User#initialize` surfacing as `@name: String` on
      # `Example3`. With no target (caller files), everything is collected.
      return super unless inside_target?

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
