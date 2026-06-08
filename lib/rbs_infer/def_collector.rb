module RbsInfer
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

    def visit_def_node(node)
      @defs << node
      @owners[node] = current_owner
      super
    end

    # Owner of a previously-collected def node (nil = direct class member).
    def owner_of(node)
      @owners[node]
    end
  end
end
