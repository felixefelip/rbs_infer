# frozen_string_literal: true

module RbsInfer::AST
  # Walks a (possibly macro-expanded) file tree and enumerates every
  # top-level type the file defines or reopens — the input to the
  # multi-target core (felixefelip/rbs_infer#38).
  #
  # Two kinds of target:
  #
  # - **declaration targets**: every `class` the file declares, at any
  #   nesting depth, plus each `module` declared at class/module-nesting
  #   depth 0. Blocks (`on_load`, `to_prepare`, any `do ... end`) do NOT
  #   count as nesting, so a `module M` inside a `to_prepare` block is
  #   still depth 0. Nested names are fully qualified against their
  #   enclosing declarations (`class Example2; class User` → "Example2::User").
  #
  #   A nested *module* is excluded on purpose: the owner mechanism in
  #   ClassMemberCollector/RbsBuilder emits it in place, inside its
  #   enclosing target's block (felixefelip/rbs_infer#22). That mechanism
  #   only ever handled modules, so nested *classes* used to fall through
  #   it and have their members flattened into the enclosing class — see
  #   `namespace_wrapper?` and LexicalScope#inside_target?.
  #
  # - **include targets**: `Receiver.include Mod` calls with an explicit
  #   constant receiver. These reopen `Receiver` to mix in `Mod`; there is
  #   no class body to analyze, so the core synthesizes a reopen block.
  class TargetDiscovery < Prism::Visitor
    attr_reader :include_targets, :declarations

    def initialize
      # Enclosing declaration names, outermost first — qualifies nested
      # targets. Blocks don't push, so it doubles as the depth counter.
      @namespace = []
      # Source order, each `{ name:, is_module:, namespace: }`. `namespace` marks
      # a wrapper kept only in case it turns out to be the only home a nested
      # module has — see `declaration_targets`.
      @targets = []
      # Every type the file declares, qualified name => is_module. Unlike
      # `declaration_targets` this keeps namespace wrappers and nested
      # modules: it answers "what kind is X?", not "what should we emit?".
      # The analyzer needs it to render a nested target's namespace with the
      # right keyword without hunting for a file named after it.
      @declarations = {}
      # receiver name => ordered, de-duplicated list of included module names
      @include_targets = {}
    end

    def visit_module_node(node)
      record_kind(node, is_module: true)
      record_declaration(node, is_module: true) if @namespace.empty?
      nest(node) { super }
    end

    def visit_class_node(node)
      record_kind(node, is_module: false)
      record_declaration(node, is_module: false)
      nest(node) { super }
    end

    def visit_call_node(node)
      record_include_target(node) if node.name == :include
      super
    end

    # The types to emit, in source order.
    #
    # A namespace wrapper hosting a nested module is in the list only when the
    # file has a target of its own. The nested module is emitted inside its
    # enclosing target's block and nowhere else, so with a sibling class in the
    # file — `class C; module Foo; …; end; class Bar; end; end` — dropping the
    # wrapper dropped `Foo` with it and the file emitted `C::Bar` alone. With no
    # other target the file takes the single-target path, which already lands
    # on the wrapper via
    # `ClassNameExtractor`, and adding it here would only flatten that nesting.
    def declaration_targets
      real = @targets.reject { |t| t[:namespace] }
      chosen = real.empty? ? real : @targets
      chosen.map { |t| { name: t[:name], is_module: t[:is_module] } }
    end

    private

    def nest(node)
      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return yield unless name && !name.empty?

      @namespace.push(name)
      yield
    ensure
      @namespace.pop if name && !name.empty?
    end

    def record_kind(node, is_module:)
      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return unless name && !name.empty?

      @declarations[(@namespace + [name]).join("::")] = is_module
    end

    def record_declaration(node, is_module:)
      wrapper = namespace_wrapper?(node)
      return if wrapper && !hosts_orphan_module?(node)

      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return unless name && !name.empty?

      qualified = (@namespace + [name]).join("::")

      # ONE target per name, however many times the file reopens it. Ruby reopens a
      # class rather than redefining it, and a target's pass already collects members
      # from every reopen in the file — so a second entry re-emitted the whole merged
      # set, and two declarations of the same method in one file is an RBS
      # `DuplicatedMethodDefinitionError`: `build_instance` raises for that class, so
      # it poisons the environment rather than just the one file.
      #
      # Latent while no fixture reopened a class twice in a single file; the
      # `class_eval` desugaring makes it the normal case, since it emits a `class X`
      # beside the one the file already writes.
      return if @targets.any? { |t| t[:name] == qualified }

      @targets << { name: qualified, is_module: is_module, namespace: wrapper }
    end

    # A module declared directly in `node`'s body that has something of its own
    # to emit — so the owner mechanism has to write it into `node`'s block,
    # because a nested module is never a target of its own. That is what makes
    # an otherwise droppable wrapper worth keeping.
    #
    # Recursive, because a namespace module can host one: `module Baz` holding
    # nothing but two empty modules is a wrapper by the rule above, and dropping
    # its enclosing target dropped BOTH of them — an empty module still declares
    # a type, and it is the only place that type can be written
    # (felixefelip/rbs_infer#268). A nested CLASS never needs this: classes are
    # targets at any depth and emit their own block.
    def hosts_orphan_module?(node)
      node.body.body.any? do |stmt|
        next false unless stmt.is_a?(Prism::ModuleNode)

        !namespace_wrapper?(stmt) || hosts_orphan_module?(stmt)
      end
    end

    # A declaration whose body is nothing but other class/module declarations
    # (`module Admin; class User; ...; end; end`) is a pure namespace: it has
    # no members of its own to emit. RbsBuilder already re-declares every
    # enclosing namespace around each nested target, so making the wrapper a
    # target too would only add a redundant empty block next to the real one.
    #
    # An *empty* body is NOT a wrapper — `class A; end` declares a real (if
    # memberless) type and stays a target.
    def namespace_wrapper?(node)
      body = node.body
      return false if body.nil?

      stmts = body.body
      return false if stmts.empty?

      stmts.all? { |stmt| stmt.is_a?(Prism::ClassNode) || stmt.is_a?(Prism::ModuleNode) }
    end

    def record_include_target(node)
      receiver = node.receiver
      return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

      receiver_name = RbsInfer::Analyzer.extract_constant_path(receiver)
      return unless receiver_name && node.arguments

      modules = node.arguments.arguments.filter_map { |arg| RbsInfer::Analyzer.extract_constant_path(arg) }
      return if modules.empty?

      list = (@include_targets[receiver_name] ||= [])
      list.concat(modules)
      list.uniq!
    end
  end
end
