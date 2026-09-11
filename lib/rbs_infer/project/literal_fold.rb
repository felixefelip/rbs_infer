# frozen_string_literal: true

require "prism"

module RbsInfer::Project
  # What a Ruby expression evaluates to, read from the source alone plus a set
  # of bindings for the names in scope.
  #
  # Written for `StringEvalMacroExpander`, which has to ask the same question
  # twice about the same macro body — "what text does `#{name}` interpolate to
  # here" and "does this `if` run here" — and used to answer it with two
  # separate readers. Two readers meant two ideas of "I cannot tell", and the
  # one on the condition side mapped its unknown onto `false`. `false` is not a
  # refusal, it is an ANSWER: a predicate the reader could not read selected the
  # `else` branch, and the macro emitted the methods that branch defines.
  #
  # So both sides are one function here, propagating ONE unknown. That is the
  # point of the module, more than any expression it happens to fold: a caller
  # cannot accidentally treat "I could not read this" as "this is falsy",
  # because the two are not the same value.
  #
  # The domain is `String | Symbol | true | false | nil | UNKNOWN`. Deliberately
  # small — this reads a macro's own parameters at a call site, not a program.
  # Anything outside it (a constant, a method call, an ivar, arithmetic) is
  # UNKNOWN, which is a refusal and never a guess.
  module LiteralFold
    # Its own object rather than a Symbol: `slot :unknown` binds a parameter to
    # the symbol `:unknown`, and a sentinel a call site can spell is a sentinel
    # that lies. Compared with `equal?` everywhere for the same reason.
    UNKNOWN = Object.new
    def UNKNOWN.inspect = "RbsInfer::Project::LiteralFold::UNKNOWN"
    UNKNOWN.freeze

    module_function

    def unknown?(value)
      UNKNOWN.equal?(value)
    end

    # `bindings` maps a name to the NODE it is bound to — a call site's argument
    # or the definition's default — so a binding is itself folded, once.
    #
    # `seen` breaks the cycle a call site can write: `slot name` inside a body
    # where `name` is also the macro's own parameter would otherwise fold to
    # itself forever.
    def fold(node, bindings, seen = [])
      return UNKNOWN if node.nil? || seen.any? { |other| other.equal?(node) }

      seen += [node]

      case node
      when Prism::StringNode then node.unescaped
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      when Prism::InterpolatedStringNode then interpolated(node, bindings, seen)
      when Prism::InterpolatedSymbolNode then symbolized(interpolated(node, bindings, seen))
      when Prism::StatementsNode then fold(only_statement(node), bindings, seen)
      when Prism::ParenthesesNode then fold(node.body, bindings, seen)
      when Prism::ElseNode then fold(node.statements, bindings, seen)
      when Prism::AndNode then short_circuit(node, bindings, seen, stop_on: false)
      when Prism::OrNode then short_circuit(node, bindings, seen, stop_on: true)
      when Prism::IfNode then branch(node.predicate, node.statements, node.subsequent, bindings, seen)
      when Prism::UnlessNode then branch(node.predicate, node.else_clause, node.statements, bindings, seen)
      when Prism::LocalVariableReadNode then bound(node.name, bindings, seen)
      when Prism::CallNode then call(node, bindings, seen)
      else UNKNOWN
      end
    end

    # Ruby's own truthiness, with the unknown passed through rather than
    # collapsed — the whole reason this module exists.
    def truthy(value)
      return UNKNOWN if unknown?(value)

      !!value
    end

    # The text a value interpolates to, by Ruby's rules — except `nil`, which
    # interpolates to "" and so would turn `def #{name}` into `def `. That is a
    # SyntaxError at `class_eval` time, not a definition, so it is refused here
    # rather than rendered.
    def to_text(value)
      return UNKNOWN if unknown?(value) || value.nil?

      value.to_s
    end

    # A name is bound only when the binder put it there. A name it did not —
    # a local of the macro's own body, a method it calls — is unknown, and must
    # not read as the `nil` a missing hash key would give.
    def bound(name, bindings, seen)
      return UNKNOWN unless bindings.key?(name)

      fold(bindings[name], bindings, seen)
    end

    # A receiverless call taking nothing is how a method's own parameter reads
    # inside its body, where Prism cannot tell a local from a call. Beyond that,
    # only the two operators a macro actually branches on.
    def call(node, bindings, seen)
      return UNKNOWN unless node.block.nil?

      arguments = node.arguments&.arguments || []
      return bound(node.name, bindings, seen) if node.receiver.nil? && arguments.empty?
      return UNKNOWN if node.receiver.nil?

      case node.name
      when :! then negated(node.receiver, arguments, bindings, seen)
      when :==, :!= then compared(node, arguments, bindings, seen)
      else UNKNOWN
      end
    end

    def negated(receiver, arguments, bindings, seen)
      return UNKNOWN unless arguments.empty?

      value = truthy(fold(receiver, bindings, seen))
      unknown?(value) ? UNKNOWN : !value
    end

    def compared(node, arguments, bindings, seen)
      return UNKNOWN unless arguments.size == 1

      left = fold(node.receiver, bindings, seen)
      right = fold(arguments.first, bindings, seen)
      return UNKNOWN if unknown?(left) || unknown?(right)

      node.name == :== ? left == right : left != right
    end

    def short_circuit(node, bindings, seen, stop_on:)
      left = fold(node.left, bindings, seen)
      decided = truthy(left)
      return UNKNOWN if unknown?(decided)
      return left if decided == stop_on

      fold(node.right, bindings, seen)
    end

    def branch(predicate, taken, otherwise, bindings, seen)
      decided = truthy(fold(predicate, bindings, seen))
      return UNKNOWN if unknown?(decided)
      return fold(taken, bindings, seen) if decided

      otherwise.nil? ? nil : fold(otherwise, bindings, seen)
    end

    def interpolated(node, bindings, seen)
      text = +""

      node.parts.each do |part|
        piece = case part
                when Prism::StringNode then part.unescaped
                when Prism::EmbeddedStatementsNode
                  to_text(fold(only_statement(part.statements), bindings, seen))
                else UNKNOWN
                end
        return UNKNOWN if unknown?(piece)

        text << piece
      end

      text
    end

    def symbolized(value)
      unknown?(value) ? UNKNOWN : value.to_sym
    end

    # One statement, or nothing. A body with several has a value this does not
    # read, since everything but the last is evaluated for its effect.
    def only_statement(statements)
      body = statements.is_a?(Prism::StatementsNode) ? statements.body : nil
      body&.size == 1 ? body.first : nil
    end
  end
end
