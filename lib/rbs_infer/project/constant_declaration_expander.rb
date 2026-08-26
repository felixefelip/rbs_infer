# frozen_string_literal: true

require "prism"
require_relative "source_expanders"
require_relative "block_reopen"

module RbsInfer::Project
  # Desugars a constant whose value is a FRESH module or class into the
  # declaration it is:
  #
  #   BananaWritten = Module.new              # => module BananaWritten; end
  #   const_set(:BananaDynamic, Module.new)   # => module BananaDynamic; end
  #   Erro = Class.new(StandardError)         # => class Erro < StandardError; end
  #
  # Ruby draws no line between these and the keyword form: `Module.new` assigned
  # to a constant takes that constant's name (`BananaWritten.name` answers
  # `"Example46::Baz::BananaWritten"`), and `const_set` is the same assignment
  # with the name written as data. A human reads all three as "here is a module
  # called X".
  #
  # The pipeline read none of them. `X = Module.new` came out as a MEMBER —
  # `BananaWritten: Module`, a constant holding some module rather than a type
  # anything can be — and `const_set` came out as nothing at all, so a later
  # `include`/`extend` of the name resolved to nowhere and every method reached
  # through it degraded to `untyped` (felixefelip/rbs_infer#268).
  #
  # Only a statement written DIRECTLY in a class/module body (or at top level)
  # is rewritten, which is what makes the rewrite in place legal: a call there
  # sits exactly where a declaration may sit — the argument `ClassEvalExpander`
  # makes for the same move. A `const_set` inside a method body is the other
  # question entirely (which object is `self` when it runs), and is left alone;
  # that is what Rails' own `class_methods` writes, and it needs the replay
  # machinery rather than a lexical rewrite.
  #
  # Core, not an extension: `Module.new` and `const_set` are plain Ruby, so the
  # litmus in docs/engineering/keep-core-framework-agnostic.md ("would this make
  # sense for a gem that doesn't exist?") says yes. The seam is used anyway
  # because the desugared declaration then flows through the same
  # member/visibility/return-type machinery every keyword-declared module uses.
  module ConstantDeclarationExpander
    # `X = Class.new do Y = Module.new end` — the inner statement is inside a
    # BLOCK on the first pass, so nothing collects it; once the outer one is a
    # real class body it is an ordinary statement. Same reason
    # `ClassEvalExpander` iterates.
    MAX_PASSES = 10

    # The two constructors this reads, and what each declares. Listed rather
    # than duck-typed on `.new`: `Struct.new` and `Data.define` also answer with
    # a fresh class, and they declare MEMBERS too — reading them as a bare
    # `class X` would emit a class whose accessors are missing, which is worse
    # than emitting nothing.
    CONSTRUCTORS = { "Module" => "module", "Class" => "class" }.freeze

    # What a constant may be named. `const_set` takes its name as data, so this
    # is also the check that the data IS a constant name — `const_set(:foo, …)`
    # raises at runtime and declares nothing.
    CONSTANT_NAME = /\A[A-Z][A-Za-z0-9_]*\z/

    module_function

    # Returns the expanded source, or nil when there is nothing to rewrite.
    def expand(source)
      result = nil

      MAX_PASSES.times do
        expanded = expand_once(result || source)
        break unless expanded

        result = expanded
      end

      result
    end

    def expand_once(source)
      return nil unless possible?(source)

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      collector = Collector.new
      parsed.value.accept(collector)

      replacements = collector.statements.filter_map { |node| replacement_for(source, node) }
      return nil if replacements.empty?

      apply_replacements(source, replacements)
    end

    # The cheap gate. A project that never builds a module at runtime pays one
    # substring scan and nothing else.
    def possible?(source)
      source.include?("Module.new") || source.include?("Class.new") || source.include?("const_set")
    end

    # Every statement written DIRECTLY in a class body, a module body, or at top
    # level — the three places a declaration may stand. A `def`'s body, an `if`,
    # a block: not collected, because a `module X … end` cannot go there.
    #
    # `class << self` is deliberately not among them. A constant assigned in a
    # singleton class body belongs to the SINGLETON (`Foo.singleton_class::X`),
    # which is not a name the pipeline can emit a declaration under.
    class Collector < Prism::Visitor
      attr_reader :statements

      def initialize
        @statements = []
        super()
      end

      def visit_program_node(node)
        collect(node.statements)
        super
      end

      def visit_class_node(node)
        collect(node.body)
        super
      end

      def visit_module_node(node)
        collect(node.body)
        super
      end

      private

      def collect(body)
        @statements.concat(body.body) if body.is_a?(Prism::StatementsNode)
      end
    end

    def replacement_for(source, node)
      name, value = declaration(node)
      return nil unless name

      # The STATEMENT's column, not the value's: `X = Module.new` puts the
      # value mid-line, and aligning to it would indent the closing `end` to
      # the `Module`.
      text = rendered(source, name, value, indent: BlockReopen.line_indent(source, node.location.start_offset))
      return nil unless text

      { start: node.location.start_offset, end: node.location.end_offset, text: text }
    end

    # `[constant name, value node]` for the two spellings, else nil.
    def declaration(node)
      case node
      when Prism::ConstantWriteNode
        [node.name.to_s, node.value]
      when Prism::CallNode
        const_set_declaration(node)
      end
    end

    # `const_set(:X, <value>)` on our own `self`. A receiver names another
    # object, and which module that is is not a question a lexical rewrite can
    # answer — the target would be somebody else's namespace.
    def const_set_declaration(node)
      return nil unless node.name == :const_set
      return nil unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

      arguments = node.arguments&.arguments || []
      return nil unless arguments.size == 2

      name = literal_name(arguments.first)
      [name, arguments.last] if name
    end

    # The name a `const_set` is given, when it is written as data rather than
    # computed. An interpolated symbol or a variable is the undecidable case and
    # answers nil.
    def literal_name(node)
      return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

      name = node.unescaped
      name if name&.match?(CONSTANT_NAME)
    end

    # The declaration `value` stands for, rendered at `indent`, or nil when the
    # value is not a fresh module or class.
    def rendered(source, name, value, indent:)
      return nil unless value.is_a?(Prism::CallNode) && value.name == :new

      kind = CONSTRUCTORS[top_level_constant(value.receiver)]
      return nil unless kind

      arguments = value.arguments&.arguments || []
      superclass = superclass_for(kind, arguments)
      return nil if superclass == :decline

      body = body_of(value.block)
      return nil if body == :decline

      header = "#{kind} #{name}#{superclass}"
      inner = body && BlockReopen.body_source(source, body, indent: indent + BlockReopen::INDENT)

      [header, inner, "#{indent}end"].compact.join("\n")
    end

    # `Module` and `Class` themselves, written bare or fully qualified. Any
    # other receiver — including a constant that merely ENDS in `Class` — is
    # somebody else's `new`.
    def top_level_constant(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.parent.nil? ? node.name.to_s : nil
      end
    end

    # `" < Super"`, `""`, or `:decline`.
    #
    # `Module.new` takes no arguments and `Class.new` takes at most one, so
    # anything else is a call this does not recognise. The superclass must be a
    # CONSTANT: `Class.new(base_class)` names a class the source does not say.
    def superclass_for(kind, arguments)
      return "" if arguments.empty?
      return :decline unless kind == "class" && arguments.size == 1

      name = RbsInfer::Analyzer.extract_constant_path(arguments.first)
      name ? " < #{name}" : :decline
    end

    # The block's body, nil when there is no block, or `:decline` for a block
    # this cannot move. `Module.new { |mod| … }` binds the new module to a
    # PARAMETER, and the body reads it under that name — a name that no longer
    # exists once the body is a module body.
    def body_of(block)
      return nil unless block

      return :decline unless block.is_a?(Prism::BlockNode)
      return :decline if block.parameters

      block.body
    end

    # Back to front so earlier byte offsets stay valid (mirrors the other
    # expanders). Two direct statements of one body cannot overlap, so ordering
    # is all the sorting has to do.
    def apply_replacements(source, replacements)
      out = source.dup
      replacements.sort_by { |r| -r[:start] }.each do |r|
        out = out.byteslice(0, r[:start]) + r[:text] + out.byteslice(r[:end]..)
      end
      out
    end
  end

  SourceExpanders.register(ConstantDeclarationExpander)
end
