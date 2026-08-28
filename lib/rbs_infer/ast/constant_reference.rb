# frozen_string_literal: true

require "prism"
require_relative "../inference/send_call"

# Nested rather than written as the `RbsInfer::AST` shorthand most of `ast/`
# uses, for the reason `LexicalConstantResolver` gives: the shorthand needs
# `RbsInfer` to exist already, and this file can be required on its own, before
# the core is loaded.
module RbsInfer
  module AST
    # Which constant an expression NAMES, for the two ways Ruby lets one be written.
    #
    # As SYNTAX (`Foo::Bar`), where the name is in the program text and means what
    # it means in the lexical scope it was written in. Or as DATA
    # (`const_get(:Bar)`), where the name is a value and the namespace it is looked
    # up in is whatever `self` is when the line runs — which the writing scope does
    # not decide.
    #
    # That difference is the whole reason this answers a PAIR rather than a name.
    # It is a fact about Ruby, not about any one caller: `base.extend(Written)` and
    # `base.extend(const_get(:Written))` in the same hook name two different
    # modules, and reading both as "a constant called Written" resolves one of them
    # against the wrong namespace (felixefelip/rbs_infer#268).
    #
    # Deliberately knows nothing about WHERE constants live — that is
    # `LexicalConstantResolver`'s question, and the caller's — nor about what the
    # named module is for. This module only reads the expression.
    module ConstantReference
      # What a constant may be named. `const_get` and `const_set` take the name as
      # data, so this is also the check that the data IS a constant name —
      # `const_get(:foo)` raises at runtime and names nothing.
      CONSTANT_NAME = /\A[A-Z][A-Za-z0-9_]*\z/

      # The two constructors that build a fresh namespace, and what each
      # declares. Listed rather than duck-typed on `.new`: `Struct.new` and
      # `Data.define` also answer with a fresh class, and they declare MEMBERS
      # too, so reading them as a bare `class X` would name a type whose
      # accessors are missing.
      CONSTRUCTORS = { "Module" => "module", "Class" => "class" }.freeze

      module_function

      # What an expression names, as `[name, dynamic?, creates]`.
      #
      # `[node, false, nil]` for a constant written as syntax — the node itself,
      # since resolving it needs the lexical scope the caller knows and this
      # module does not. `[name, true, nil]` for one fetched as data. nil when
      # the expression names no constant the source decides.
      #
      # `creates` is what the expression brings into existence — "module",
      # "class", or nil for one that only reaches for something already there.
      # A third answer rather than a second question, because
      # `const_set(:X, Module.new)` gives both at once: it names X, and it is the
      # reason X exists. A caller that requires the constant to be declared
      # already has to tell the two apart — `const_get` on a module nobody
      # defined raises, and `const_set` is what defines it
      # (felixefelip/rbs_infer#268).
      def named(node)
        return [node, false, nil] if RbsInfer::Analyzer.extract_constant_path(node)
        if (created = set_name(node))
          return created
        end


        name = fetched_name(node)
        [name, true, nil] if name
      end

      # `const_set(:X, Module.new)` on our own `self` — the name it gives and
      # what it makes. Same two restrictions as `fetched_name`, for the same
      # reasons: a receiver names another object's namespace, and a computed name
      # is a runtime answer.
      #
      # Only a FRESH module or class counts. `const_set(:X, whatever)` names X
      # too, but says nothing about what X is, and a caller reading this wants a
      # type it can reopen — the line `ConstantDeclarationExpander` draws for the
      # assignment spelling, drawn once here for both.
      def set_name(node)
        return nil unless node.is_a?(Prism::CallNode)

        call = RbsInfer::Inference::SendCall.desugar(node) || node
        return nil unless call.name == :const_set
        return nil unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

        arguments = call.arguments&.arguments || []
        return nil unless arguments.size == 2

        name = literal_name(arguments.first)
        kind = constructed_kind(arguments.last)
        [name, true, kind] if name && kind
      end

      # What a `Module.new` / `Class.new` constructs, as the keyword that
      # declares it, or nil for anything else. `Module` and `Class` themselves,
      # written bare or fully qualified — a constant that merely ENDS in `Class`
      # is somebody else's `new`.
      def constructed_kind(node)
        return nil unless node.is_a?(Prism::CallNode) && node.name == :new

        CONSTRUCTORS[top_level_constant(node.receiver)]
      end

      def top_level_constant(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then node.parent.nil? ? node.name.to_s : nil
        end
      end

      # The name in `const_get(:X)` / `const_get("X")` on our own `self`.
      #
      # A RECEIVER names another object, and which module that is is not a question
      # the source answers — the same line `ConstantDeclarationExpander` draws for
      # `const_set`. A COMPUTED name (`const_get(:"#{prefix}Methods")`) is declined
      # for the reason felixefelip/rbs_infer#268 draws it: which constant that
      # reaches is a runtime answer.
      #
      # Read through `SendCall`, so `mod.send(:const_get, :X)` is the same call —
      # which is the spelling a caller reaches for when the method is private, and
      # `const_get` is public but its neighbours in these hooks are not.
      def fetched_name(node)
        return nil unless node.is_a?(Prism::CallNode)

        call = RbsInfer::Inference::SendCall.desugar(node) || node
        # `const_get` only. `const_defined?` asks a question rather than naming a
        # constant to use, and a caller that wants the guard's meaning has the
        # declarations to answer it with.
        return nil unless call.name == :const_get
        return nil unless call.receiver.nil? || call.receiver.is_a?(Prism::SelfNode)

        arguments = call.arguments&.arguments || []
        return nil unless arguments.size == 1

        literal_name(arguments.first)
      end

      # The constant name an argument spells, when it spells one at all. An
      # interpolated symbol, a variable, and a name no constant may have all answer
      # nil.
      #
      # `Inference::SendCall.literal_name` is the same reading for a METHOD name,
      # and stays separate: it answers a Symbol and accepts any name a method may
      # have, which is nearly every name and so would accept `:foo` here.
      def literal_name(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        name = node.unescaped
        name if name&.match?(CONSTANT_NAME)
      end
    end
  end
end
