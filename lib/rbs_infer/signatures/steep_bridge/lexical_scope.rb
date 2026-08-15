class RbsInfer::Signatures::SteepBridge
  class LexicalScope
    class << self
      # A `[name, kind]` namespace frame for a `:class`/`:module` node, or the
      # unchanged namespace for an anonymous one.
      def push_namespace(namespace, node)
        name = const_node_to_name(node.children[0])
        name ? namespace + [[name, node.type]] : namespace
      end

      # Whether a write at lexical `namespace` (a list of `[name, kind]` frames,
      # outermost first) belongs to `target_class`. Exactly — the scope that
      # WRITES an ivar is the scope that owns it. A nil `target_class` means
      # "don't scope" (whole file), preserved for callers with no single target.
      #
      # A nested module used to count as the target too, so that a nested
      # `module GeneratedAttributeMethods` the class `include`s would put its
      # ivars on the class. It reached the right conclusion the wrong way: the
      # includer sees the slot because RBS resolves instance variables through
      # ANCESTORS, so declaring `@x` on the module already gives every includer
      # `@x` — the loophole was never what made that case work.
      #
      # What it did do is claim ivars from modules nobody includes. `Example32`'s
      # `Foo` is only ever `extend`ed, so `@_bazingado_block` was declared on
      # `Example32`, which no runtime object ever writes it on, and Steep
      # answered `Cannot find the declaration of instance variable` at the write
      # itself (felixefelip/rbs_infer#249).
      #
      # The nested module's ivars are emitted in its own `module … end` block by
      # `RbsBuilder`, alongside the members the owner mechanism already put there
      # (felixefelip/rbs_infer#22).
      def class_scope_match?(namespace, target_class)
        return true if target_class.nil?

        namespace.map(&:first).join("::") == target_class.to_s.sub(/\A::/, "")
      end

      private

      # Renders a whitequark `:const` node into a dotted class-path string:
      # `(const nil :Foo)` → "Foo", `(const (const nil :Foo) :Bar)` →
      # "Foo::Bar", `(const (cbase) :Foo)` → "Foo". Returns nil for shapes
      # we can't name (dynamic constant paths), so the caller keeps the
      # outer namespace rather than inventing a segment.
      def const_node_to_name(node)
        return nil unless node.is_a?(::Parser::AST::Node) && node.type == :const

        scope, name = node.children
        if scope.nil? || (scope.is_a?(::Parser::AST::Node) && scope.type == :cbase)
          name.to_s
        elsif scope.is_a?(::Parser::AST::Node) && scope.type == :const
          prefix = const_node_to_name(scope)
          prefix ? "#{prefix}::#{name}" : nil
        end
      end
    end
  end
end
