# frozen_string_literal: true

module RbsInfer
  module Inference
    class ClassMemberCollector < Prism::Visitor
      # Where the body calls a positional parameter as a proc — `default_proc.call(self, key)` —
      # one entry per argument slot, the same shape `BlockSignature#arg_positions` has for the
      # block. A `self` argument is recorded as `:self` rather than a position: what it passes
      # is the receiver, which a signature spells `self` whatever class the checker would name.
      #
      # Only parameters every call agrees on the arity of are kept, and a splat or a keyword
      # argument leaves the arity unknown.
      class ProcParamCalls
        UNCOUNTED = [Prism::SplatNode, Prism::KeywordHashNode, Prism::BlockArgumentNode,
                     Prism::ForwardingArgumentsNode].freeze

        def initialize(params, body:)
          @params = params
          @body = body
        end

        def call
          return {} unless @params && @body

          names.each_with_object({}) do |name, found|
            arity = arity_of(sites = call_sites(name)) or next

            found[name] = Array.new(arity) { |slot| sites.map { |args| entry(args[slot]) } }
          end
        end

        private

        def names
          positionals = [*@params.requireds, *@params.optionals, *@params.posts]
          positionals.filter_map { |param| param.name.to_s if param.respond_to?(:name) && param.name }
        end

        def arity_of(sites)
          return nil if sites.flatten.any? { |arg| UNCOUNTED.any? { |kind| arg.is_a?(kind) } }

          arities = sites.map(&:size).uniq
          arities.first if arities.size == 1 && arities.first.positive?
        end

        def call_sites(name)
          sites = []
          RbsInfer::Analyzer.find_all_nodes(@body) do |node|
            sites << (node.arguments&.arguments || []) if called?(node, name)
            false
          end
          sites
        end

        def called?(node, name)
          node.is_a?(Prism::CallNode) && node.name == :call &&
            node.receiver.is_a?(Prism::LocalVariableReadNode) && node.receiver.name.to_s == name
        end

        def entry(node)
          return :self if node.is_a?(Prism::SelfNode)

          loc = node.location
          [loc.start_line, loc.start_character_column, loc.end_line, loc.end_character_column]
        end
      end
    end
  end
end
