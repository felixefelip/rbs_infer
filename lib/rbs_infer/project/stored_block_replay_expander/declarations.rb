# frozen_string_literal: true

require "set"
require_relative "shapes"

module RbsInfer::Project::StoredBlockReplayExpander
  # What a file DECLARES, and everything that follows from it: which names exist,
  # with which keyword, under which enclosing scope, over which superclass — and,
  # from all of that, which module can call whose DSL.
  #
  # It is written by the lexical walk and read by every later phase, which is why
  # it was eight instance variables spread across a class that also collects
  # shapes and resolves replays (felixefelip/rbs_infer#305). Gathered here they
  # answer one question each, under names that say what is being asked:
  # `resolve` is a constant lookup, `kind_of` is "class or module", `providers`
  # is the mixin relation.
  #
  # A NAME is not a constant, and the difference is this object's whole subject.
  # `include Fields` inside `class Filter` means `Filter::Fields` in one project
  # and a top-level `Fields` in another, and only the declarations settle which
  # (felixefelip/rbs_infer#289).
  class Declarations
    include Shapes

    def initialize
      @scope = []
      @names = Set.new
      @kinds = {}
      # What the files this one absorbs shapes from DECLARE. Read for one
      # question only — is the module a `const_get` names actually there — which
      # is why it is kept apart from `@kinds`: every other reader of that hash is
      # asking about a declaration THIS file makes, and widening it would answer
      # them about somebody else's.
      @absorbed_kinds = {}
      # Namespaces this file's own DSL calls BRING INTO EXISTENCE —
      # `const_set(:X, Module.new)` under the subject that called it. Filled
      # while the replays resolve and read back by everything that asks whether a
      # name is declared: the module is not in any file's text, and the reopening
      # this pass emits for it is what declares it.
      @created_kinds = {}
      @extends = []
      @superclasses = []
      # Who can call whose DSL, as the files this one absorbs write it. Kept
      # apart from the table this file builds for the same reason
      # `@absorbed_kinds` is: one is a fact about this source, the other about
      # somebody else's, and only the merge answers "who supplies this method".
      @absorbed_providers = Hash.new { |hash, key| hash[key] = Set.new }
    end

    # The class/module names this file declares, and the keyword each was
    # declared with. Both are read by the collector that ABSORBS this file.
    attr_reader :names, :kinds

    # Records a `class`/`module` node and runs the block inside it.
    #
    # The `ensure` pops only the name this call pushed: a body that raises must
    # not leave the scope stack describing a namespace nobody is in.
    def enter(node)
      name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      return yield unless name

      qualified = qualify(name)
      @names << qualified
      @kinds[qualified] = node.is_a?(Prism::ModuleNode) ? "module" : "class"
      @superclasses << [qualified, node.superclass] if node.is_a?(Prism::ClassNode) && node.superclass
      @scope << qualified
      yield
    ensure
      @scope.pop if @scope.last == qualified
    end

    def current_scope
      @scope.last
    end

    def record_extend(subject, argument)
      @extends << [subject, argument]
    end

    # A name this file can now answer for, because the corpus walk reached it.
    def declare_all(reached)
      @names.merge(reached)
    end

    def record_created(name, kind)
      @created_kinds[name] = kind
    end

    def absorb(kinds:, providers:)
      @absorbed_kinds.merge!(kinds)
      providers.each { |owner, subjects| @absorbed_providers[owner].merge(subjects) }
    end

    # The constant `node` names, read where it was WRITTEN, or nil when this file
    # declares nothing by that name.
    #
    # Conditional on the declarations, like every other answer here. A non-nil
    # return means "this file declares this", and `external_lookups` reads that
    # as "nothing to absorb" — so answering unconditionally would say that about
    # `include ::Storage::Tracked` in `board.rb`, the concern's file would never
    # be opened, and `Board` would drop out of the very list it belongs to
    # (felixefelip/rbs_infer#299).
    def resolve(node, context)
      name = RbsInfer::Analyzer.extract_constant_path(node)
      return nil unless name

      if name.start_with?("::")
        top_level = name.delete_prefix("::")
        return @names.include?(top_level) ? top_level : nil
      end

      return name if name.include?("::") && @names.include?(name)

      prefixes = context.to_s.split("::")
      prefixes.length.downto(1) do |length|
        candidate = "#{prefixes.take(length).join("::")}::#{name}"
        return candidate if @names.include?(candidate)
      end
      @names.include?(name) ? name : nil
    end

    # Whether a name is declared anywhere this file can see, and with what
    # keyword — its own text, a file it absorbed, or a namespace a DSL call
    # brought into existence.
    def kind_of(name)
      @kinds[name] || @absorbed_kinds[name] || @created_kinds[name]
    end

    def module?(name)
      kind_of(name) == "module"
    end

    # The keyword THIS file declared a name with, and nothing wider. A reopening
    # is emitted only for a class this source names, so an absorbed or created
    # kind is not an answer to that question.
    def own_kind(name)
      @kinds[name]
    end

    # Which method table a `def` puts the method in, in the terms `providers`
    # keys on. `def keep` goes in the module's own, reached by whoever `extend`s
    # it; `def self.keep` goes in the SINGLETON's, reached by the subject in its
    # own body and by its subclasses. Both used to be recorded under the lexical
    # scope, which happened to work only because no dispatch runs is a runtime
    # answer, and this pass does not guess.
    #
    # `def SomeOther.foo` and `def obj.foo` answer nothing: which object that
    # names is not something a source walk decides.
    def owner_for(node)
      return current_scope unless node.receiver
      return self.class.singleton_owner(current_scope) if node.receiver.is_a?(Prism::SelfNode)

      nil
    end

    # Every constant this file NAMES in a position that says where methods come
    # from — an `extend` and a superclass. The apply arguments are the collector's
    # to add, being call sites rather than declarations.
    def named_constants
      @extends + @superclasses
    end

    # Which classes/modules can call each owner's DSL, as `owner => subjects`.
    #
    # `extend Builder` is one way to be handed those methods; `class Sub < Base`
    # is the other, and to a caller they are indistinguishable — `bazingado`
    # arrives with no receiver in the class body either way. Reading only the
    # first was the whole reason a file spelling the same replay through
    # inheritance produced nothing (felixefelip/rbs_infer#251).
    #
    # Ancestry is transitive because Ruby's is: `Bar < Baz < Foo` puts Foo's
    # singleton methods in Bar's body just as directly as `Bar < Foo` would.
    def providers
      table = Hash.new { |hash, key| hash[key] = Set.new }
      @absorbed_providers.each { |owner, subjects| table[owner].merge(subjects) }

      @extends.each do |subject, raw_module|
        mod = resolve(raw_module, subject) || self.class.written_constant(raw_module)
        table[mod] << subject if mod
      end

      parents = @superclasses.to_h { |subject, raw| [subject, resolve(raw, subject)] }
      parents.compact!

      # Through the SINGLETON, both of them. `keep` in a class body is a call on
      # the class object, so it is found in `singleton(Base)` — where
      # `def self.keep` put it — and never in `Base`'s own method table, where
      # `extend`'s half lives. Keyed alike, an `attr_reader :body` in a class
      # body would answer for a `def self.apply` that could not call it.
      @names.each do |subject|
        table[self.class.singleton_owner(subject)] << subject
        ancestors(subject, parents).each { |a| table[self.class.singleton_owner(a)] << subject }
      end

      # What the subject's own `self` makes callable: a class body reaches
      # `Class`'s instance methods and everything behind them, a module body
      # `Module`'s. To the caller this is indistinguishable from the two
      # relations above — the method arrives with no receiver either way — but it
      # is neither an `extend` nor an ancestor of the SUBJECT, so nothing above
      # can express it, and a DSL whose applier is written as a core reopening
      # had no provider at all (felixefelip/rbs_infer#256).
      @kinds.each do |subject, kind|
        CORE_SELF_CHAINS.fetch(kind, []).each { |ancestor| table[ancestor] << subject }
      end

      table
    end

    # No file can declare a constant by this name, so a singleton owner cannot
    # collide with a real one.
    def self.singleton_owner(name)
      "singleton(#{name})"
    end

    # The lexical scope a constant written in `owner`'s body resolves against.
    # `def self.included` is collected under `singleton(Foo)`, which names a
    # method table rather than a namespace: the constants a body there sees are
    # `Foo`'s.
    def self.lexical_context(owner)
      owner.to_s.sub(/\Asingleton\((.*)\)\z/, "\\1")
    end

    private

    # The name an `extend` writes, for a module this file does not declare.
    #
    # `resolve` answers nil for those, and rightly: it is picking a NAMESPACE,
    # and only a declaration it can see settles which one. A provider key needs
    # no such confirmation — it either matches the shapes some other file
    # supplied or it matches nothing, and a name nobody supplies methods under
    # changes no answer (felixefelip/rbs_infer#268).
    def self.written_constant(node)
      RbsInfer::Analyzer.extract_constant_path(node)&.sub(/\A::/, "")
    end

    def qualify(name)
      name = name.to_s.sub(/\A::/, "")
      return name if name.include?("::")

      parent = @scope.last
      parent ? "#{parent}::#{name}" : name
    end

    # `subject`'s superclass chain, nearest first, limited to classes declared in
    # this file. A chain that revisits a class it already yielded stops there:
    # `class A < B` reopened as `class B < A` is not something to reason about,
    # but it must not hang the pass either.
    def ancestors(subject, parents)
      chain = []
      current = parents[subject]
      while current && !chain.include?(current)
        chain << current
        current = parents[current]
      end
      chain
    end
  end
end
