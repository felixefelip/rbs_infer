# frozen_string_literal: true

module RbsInfer
  module Signatures
    # A constant whose value is a class is a second name for that class, and RBS
    # spells that as an alias, the only form a superclass can be written through:
    #
    #   Implementation = case
    #                    when Engine.jruby? then JavaBackend
    #                    when Engine.cruby? then MriBackend
    #                    end
    #   class Store < Implementation
    #
    # Declared `Implementation: singleton(MriBackend)`, `Store`'s superclass would
    # be a constant: a `NoSuperclassFoundError` that takes down the whole
    # environment, not just this file.
    module ClassAlias
      SINGLETON = /\Asingleton\((?<name>[\w:]+)\)\z/
      KEYWORDS = { RBS::Environment::ClassEntry => "class", RBS::Environment::ModuleEntry => "module" }.freeze

      module_function

      # `class NAME = Target` where `type` is one class or module the environment
      # declares, `NAME: type` otherwise.
      def signature(name, type, resolver)
        target = type[SINGLETON, :name]
        keyword = target && KEYWORDS[resolver.declaration(target).class]
        keyword ? "#{keyword} #{name} = #{target}" : "#{name}: #{type}"
      end

      # `superclass`, unless the file writes it as a constant the environment
      # does not declare as an alias yet: a pass that has not typed the constant
      # leaves the superclass out rather than name a constant as a class.
      def superclass(superclass, tree:, namespace:, resolver:)
        return superclass unless superclass && assigned_constants(tree).include?(superclass.split("::").last)

        enclosing = namespace.split("::")[0...-1].join("::")
        declared = RbsInfer::AST::LexicalConstantResolver.resolve(name: superclass, enclosing: enclosing) { |name| resolver.declaration(name) }
        superclass if declared && resolver.declaration(declared).is_a?(RBS::Environment::ClassAliasEntry)
      end

      def assigned_constants(tree)
        names = Set.new
        queue = [tree]
        while (node = queue.shift)
          names << node.name.to_s if node.is_a?(Prism::ConstantWriteNode)
          names << node.target.name.to_s if node.is_a?(Prism::ConstantPathWriteNode)
          queue.concat(node.compact_child_nodes)
        end
        names
      end
    end
  end
end
