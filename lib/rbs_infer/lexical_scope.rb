# frozen_string_literal: true

module RbsInfer
  # Tracks the lexical class/module nesting of a Prism visitor so members
  # and defs can be attributed to the nested module that owns them
  # (felixefelip/rbs_infer#22). Shared by ClassMemberCollector and
  # DefCollector to keep their owner computation identical.
  #
  # Owner is computed relative to the TARGET scope (`scope_target`, the
  # fully-qualified name being generated) — NOT the outermost class. This
  # matters when the target is itself nested: for `class User; module
  # Idade; ...` with target `User::Idade`, the `User` wrapper is a
  # namespace (not the primary), so `Idade`'s methods are direct members
  # (owner nil), not owned by a nested module. When `scope_target` is nil
  # or absent from the tree, nothing is owned (flat — safe default for
  # caller files and any consumer that doesn't need ownership).
  module LexicalScope
    attr_accessor :scope_target

    def scope_stack
      @scope_stack ||= []
    end

    def push_scope(kind, name)
      parent_path = scope_stack.last && scope_stack.last[:path]
      path = name ? [parent_path, name].compact.join("::") : parent_path
      scope_stack.push({ kind: kind, name: name, path: path })
    end

    def pop_scope
      scope_stack.pop
    end

    # The nested-module path owning members at the current position
    # (relative to the target scope), or nil for direct members of the
    # target / positions outside it.
    def current_owner
      target = scope_target&.sub(/\A::/, "")
      return nil unless target

      target_idx = scope_stack.index { |f| f[:path] == target }
      return nil unless target_idx

      mods = scope_stack[(target_idx + 1)..].select { |f| f[:kind] == :module && f[:name] }
      mods.empty? ? nil : mods.map { |f| f[:name] }.join("::")
    end
  end
end
