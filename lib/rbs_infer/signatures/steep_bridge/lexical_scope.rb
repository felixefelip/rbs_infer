class RbsInfer::Signatures::SteepBridge
  class LexicalScope
    class << self
			# A `[name, kind]` namespace frame for a `:class`/`:module` node, or the
			# unchanged namespace for an anonymous one.
			def push_namespace(namespace, node)
				name = const_node_to_name(node.children[0])
				name ? namespace + [[name, node.type]] : namespace
			end

			# True when the lexical class path `namespace` (array of segments) is
			# `target_class` *or* something nested under it. The nested case is
			# required: an expander (e.g. CurrentAttributes) can emit a nested
			# `module GeneratedAttributeMethods` that is `include`d into the class
			# and writes the same ivars, so its writes belong to the target. The
			# `::` boundary keeps a sibling like `BoardMember` from matching
			# target `Board`. A nil `target_class` means "don't scope" (whole
			# file), preserved for callers with no single target.
			# Whether a write at lexical `namespace` (a list of `[name, kind]` frames,
			# outermost first) belongs to `target_class`.
			#
			# Frames strictly below the target only count while they are *modules*:
			# a nested module's members are the target's, emitted in place by the
			# owner mechanism (felixefelip/rbs_infer#22). A nested *class* is its own
			# target, so its writes are not the target's — without this, `@name = name`
			# in `Example3::User#initialize` surfaced as `@name: String` on `Example3`.
			def class_scope_match?(namespace, target_class)
				return true if target_class.nil?

				target = target_class.to_s.sub(/\A::/, "")
				current = namespace.map(&:first).join("::")
				return true if current == target
				return false unless current.start_with?("#{target}::")

				namespace.drop(target.split("::").size).all? { |(_, kind)| kind == :module }
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
