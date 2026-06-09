# frozen_string_literal: true

require "prism"

module RbsInfer
  module Extensions
    module Rails
      # Extracts the transitive `self.<other> = <value-derived>` writes
      # inside a CurrentAttributes setter override that are guaranteed to
      # run whenever the setter's argument is non-nil (felixefelip#41).
      #
      #   def user=(value)
      #     super(value)
      #     self.caderneta = value.caderneta unless value.nil?
      #   end
      #
      # When `Current.user = current_user` runs under a guard (current_user
      # proven non-nil), this override also populates `Current.caderneta`.
      # Only nil-decidable guards qualify — unconditional, `if value`
      # (truthiness), `unless value.nil?` — because "value non-nil ⟹ guard
      # passes" must be sound *without* modeling `present?`/`blank?`
      # (a non-nil value can still be blank, so `if value.present?` is
      # NOT included).
      module TransitiveConstantWrites
        module_function

        # setter_defn: Prism::DefNode of the `<attr>=` override.
        # param: the value parameter's name (String).
        # => [{ attr: "caderneta", value_method: "caderneta" | nil }, ...]
        #    `value_method` nil means `self.attr = value` (the whole arg).
        def extract(setter_defn, param)
          body = setter_defn&.body
          statements = body.is_a?(Prism::StatementsNode) ? body.body : [body].compact

          statements.flat_map { |stmt| writes_from_statement(stmt, param) }
        end

        # Statements whose self-writes fire when `param` is non-nil:
        # the bare assignment, or one guarded by a nil-decidable condition.
        def writes_from_statement(stmt, param)
          case stmt
          when Prism::CallNode
            write = self_write(stmt, param)
            write ? [write] : []
          when Prism::IfNode
            return [] unless truthiness_guard?(stmt.predicate, param)
            guarded_writes(stmt.statements, param)
          when Prism::UnlessNode
            return [] unless nil_check_guard?(stmt.predicate, param)
            guarded_writes(stmt.statements, param)
          else
            []
          end
        end

        def guarded_writes(statements_node, param)
          return [] unless statements_node.is_a?(Prism::StatementsNode)

          statements_node.body.filter_map do |s|
            self_write(s, param) if s.is_a?(Prism::CallNode)
          end
        end

        # `self.<attr> = <value-derived>` → { attr:, value_method: }; nil
        # otherwise. RHS must derive from the param (`value` or
        # `value.<method>`) — anything else has no proven type from the
        # guard.
        def self_write(call, param)
          return nil unless call.receiver.is_a?(Prism::SelfNode)

          name = call.name.to_s
          return nil unless name.end_with?("=") && call.name != :== && call.name != :[]=

          rhs = call.arguments&.arguments&.first
          value_method = value_derivation(rhs, param)
          return nil if value_method == :no

          { attr: name.chomp("="), value_method: value_method }
        end

        # `value` → nil (whole arg); `value.<method>` (no args) → method
        # name; otherwise :no (not derivable from the param).
        def value_derivation(node, param)
          case node
          when Prism::LocalVariableReadNode
            node.name.to_s == param ? nil : :no
          when Prism::CallNode
            if node.receiver.is_a?(Prism::LocalVariableReadNode) &&
               node.receiver.name.to_s == param &&
               (node.arguments.nil? || node.arguments.arguments.empty?)
              node.name.to_s
            else
              :no
            end
          else
            :no
          end
        end

        # `if value` — bare truthiness on the param. Sound: a non-nil
        # class instance is truthy.
        def truthiness_guard?(predicate, param)
          predicate.is_a?(Prism::LocalVariableReadNode) && predicate.name.to_s == param
        end

        # `unless value.nil?` — the body runs iff the param is non-nil.
        def nil_check_guard?(predicate, param)
          predicate.is_a?(Prism::CallNode) &&
            predicate.name == :nil? &&
            predicate.receiver.is_a?(Prism::LocalVariableReadNode) &&
            predicate.receiver.name.to_s == param
        end
      end
    end
  end
end
