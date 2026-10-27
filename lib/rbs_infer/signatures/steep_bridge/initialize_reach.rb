# frozen_string_literal: true

module RbsInfer
  module Signatures
    class SteepBridge
      # The instance methods of `target_class` that `initialize` calls on `self`,
      # transitively, each with the namespace it is written in. A write in one of
      # them initializes the ivar as surely as a write in `initialize` does — the
      # rule `IvarTypeInferrer#collect_prism_initialized_ivars` applies to the
      # fallback (felixefelip/rbs_infer#71).
      class InitializeReach
        include Enumerable

        def initialize(node, target_class:)
          @target_class = target_class
          @defs = Hash.new { |h, k| h[k] = [] }
          collect_instance_defs(node, []) if node.is_a?(::Parser::AST::Node)
        end

        def each(&)
          reached_defs.each { |defn, namespace| defn.children[2]&.then { |body| yield body, namespace } }
        end

        private

        def reached_defs
          pending = @defs[:initialize].dup
          visited = Set[:initialize]
          reached = []
          until pending.empty?
            defn, = pending.shift
            found = self_call_names(defn.children[2]).select { |name| visited.add?(name) }
                                                     .flat_map { |name| @defs[name] }
            pending.concat(found)
            reached.concat(found)
          end
          reached
        end

        def collect_instance_defs(node, namespace)
          case node.type
          when :class, :module
            inner = LexicalScope.push_namespace(namespace, node)
            node.children.grep(::Parser::AST::Node).each { |c| collect_instance_defs(c, inner) }
          when :def
            @defs[node.children[0]] << [node, namespace] if LexicalScope.class_scope_match?(namespace, @target_class)
          when :sclass, :defs
            nil
          else
            node.children.grep(::Parser::AST::Node).each { |c| collect_instance_defs(c, namespace) }
          end
        end

        def self_call_names(node, acc = Set.new)
          return acc unless node.is_a?(::Parser::AST::Node) && !%i[def defs].include?(node.type)

          acc << node.children[1] if self_call?(node)
          node.children.each { |c| self_call_names(c, acc) }
          acc
        end

        def self_call?(node)
          receiver, name, = node.children
          node.type == :send && (receiver.nil? || receiver.type == :self) && !name.to_s.end_with?("=")
        end
      end
    end
  end
end
