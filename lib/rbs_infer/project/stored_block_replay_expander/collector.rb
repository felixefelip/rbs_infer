# frozen_string_literal: true

require "prism"
require "set"
require_relative "../../ast/constant_reference"
require_relative "../../inference/send_call"
require_relative "../constant_sources"
require_relative "shapes"
require_relative "declarations"
require_relative "shape_set"
require_relative "resolution"
require_relative "corpus"
require_relative "call_graph"
require_relative "node_reading"
require_relative "shape_reader"
require_relative "deferral_reader"

module RbsInfer::Project::StoredBlockReplayExpander
  # Collects declarations and class-body calls in one lexical pass. It keeps
  # syntax, not guessed types: resolving `Foo` in `extend Foo` and `Baz` in
  # `apply(Baz)` uses the declarations that are actually present in the file.
  class Collector < Prism::Visitor
    include Shapes

    # The `extend`s the module calls in this file put on their targets. Populated
    # by `collect`, alongside the replays it answers with: both are what a call
    # site here does to a class here, read off the same resolution.
    attr_reader :extensions

    def initialize(source, sources:)
      @source = source
      @sources = sources
      @method_depth = 0
      # Everything this file declares and what follows from it: the scope walk,
      # the kinds, the extends, the superclasses, and the provider table they
      # add up to (felixefelip/rbs_infer#305).
      @names = Declarations.new
      # What this file was read as writing, and what another file's reading is
      # merged into (felixefelip/rbs_infer#306).
      @shapes = ShapeSet.new
      # Raw like `@delegations`: reading a deferral needs the `attr_reader`s,
      # which are collected in a second lexical walk once every declaration is
      # known, so the method bodies are kept and read then.
      @deferral_shapes = []
      # Raw like `@delegations`, and resolved the same way: a constant written
      # in a hook's body may name a module declared later in the file.
      @inward_extends = []
      # Raw and resolved like the extends above, and for the same reason: the
      # constant a DSL names may be declared further down its own file.
      @own_replays = []
      # Raw like the three above, and resolved the same way: the constant a DSL
      # names may be declared further down its own file.
      @delegations = []
      # What the call sites here put on their targets, read back off the
      # resolution once it has run.
      @extensions = []
      super()
    end

    def collect(root)
      root.accept(self)
      absorb_external_shapes
      resolve_shapes

      resolution = Resolution.new(shapes: @shapes, names: @names, source: @source)
      replays = resolution.run
      @extensions = resolution.extensions
      replays
    end

    def visit_class_node(node)
      @names.enter(node) { super }
    end

    def visit_module_node(node)
      @names.enter(node) { super }
    end

    def visit_def_node(node)
      collect_method_shape(node) if @names.current_scope
      @method_depth += 1
      super
    ensure
      @method_depth -= 1
    end

    def visit_call_node(node)
      collect_class_body_call(node) if @names.current_scope && @method_depth.zero?
      super
    end

    protected

    # Everything this file says about method shapes, for a collector reading it
    # on another file's behalf. Its delegations are resolved here, against the
    # declarations of the file they were written in — which is the only place
    # the constant they name can be looked up.
    def collect_shapes(root)
      root.accept(self)
      collect_readers_from_source
      @shapes.deferrals.concat(resolve_deferrals)
      @shapes.replace(:resolved_delegations, resolve_delegations)
      @shapes.replace(:resolved_inward_extends, resolve_inward_extends)
      @shapes.replace(:resolved_own_replays, resolve_own_replays)
      # Who can call whose DSL, as THIS file writes it. A shape is only half of
      # what another file needs: `extend ActiveSupport::Concern` is written in
      # the concern, and without it a host holding the concern's shapes still
      # cannot say which owner supplies them.
      @providers = @names.providers
      self
    end

    # What this file said, for the collector absorbing it.
    attr_reader :shapes, :providers

    # What an ABSORBING collector reads off this one, answered by the
    # declarations rather than kept a second time.
    def declaration_kinds
      @names.kinds
    end

    # Every constant this file names but does not declare, each as the ORDERED
    # list of names Ruby would try for it — innermost enclosing scope first,
    # top level last.
    #
    # A name is not a constant. `include Fields` inside `class Filter` reaches
    # `Filter::Fields` in one project and a top-level `Fields` in another, and
    # the difference is which one is declared — the same question
    # `resolve_constant` already asks of this file's own declarations, asked of
    # the project instead. Reading the name as written, a relatively-included
    # concern named a constant nothing declares: `parsed_for` opened no file, so
    # the concern's shapes were never absorbed and its `included do` stayed on
    # the concern (felixefelip/rbs_infer#289).
    #
    # Candidates, not an answer, because only `parsed_for` can decide between
    # them and this method is also read by a collector that HAS no project (see
    # `absorb`). The core reopens carry a one-element list for the same reason
    # they carry a name: `Module` means `Module`, wherever it is written.
    def external_lookups
      lookups = CORE_REOPENS.map { |name| [name] }

      external_constants.each do |subject, raw_constant|
        next if @names.resolve(raw_constant, subject)

        name = RbsInfer::Analyzer.extract_constant_path(raw_constant)
        lookups << Corpus.lookup_candidates(name, subject) if name
      end

      lookups.uniq
    end

    private

    # The shapes this file wrote, resolved against the declarations now that all
    # of them are known — a constant written in a hook's body may name a module
    # declared further down, and a relative `extend Builder` needs the file's own
    # namespaces before it can be read at all.
    #
    # The last step of COLLECTING rather than the first of resolving, which is
    # why it sits here and not in `Resolution`: `collect_shapes` does the same
    # four for a file read on another's behalf, where no resolution ever runs
    # (felixefelip/rbs_infer#306).
    def resolve_shapes
      collect_readers_from_source

      @shapes.deferrals.concat(resolve_deferrals)
      @shapes.resolved_delegations.concat(resolve_delegations)
      @shapes.resolved_inward_extends.concat(resolve_inward_extends)
      @shapes.resolved_own_replays.concat(resolve_own_replays)
    end

    def collect_method_shape(node)
      owner = @names.owner_for(node)
      return unless owner

      params = node.parameters
      block_name = params&.block&.name&.to_s
      method_name = node.name.to_s

      if block_name && (ivar = ShapeReader.stored_block_ivar(node.body, block_name))
        @shapes.storages << Storage.new(owner: owner, method: method_name, ivar: ivar)
      end

      if (replay = ShapeReader.replay_shape(node.body))
        parameter, reader, singleton = replay
        @shapes.replay_methods << ReplayMethod.new(owner: owner, method: method_name, parameter: parameter, reader: reader,
                                            singleton: singleton)
      end

      parameters = NodeReading.handed_names(node.body, NodeReading.parameter_names(params))

      if (inward = ShapeReader.inward_replay_shape(node.body, parameters))
        parameter, ivar, singleton = inward
        @shapes.inward_replays << InwardReplay.new(owner: owner, method: method_name, parameter: parameter, ivar: ivar,
                                            singleton: singleton)
      end

      # Kept rather than read: the slot a deferral registers into may be reached
      # through an `attr_reader`, and no reader is known until the second walk.
      @deferral_shapes << [owner, method_name, node.body, parameters]

      ShapeReader.slot_init_shapes(node.body, parameters).each do |parameter, ivar|
        @shapes.slot_inits << SlotInit.new(owner: owner, method: method_name, parameter: parameter, ivar: ivar)
      end

      if (own = ShapeReader.own_block_replay_shape(node.body, block_name))
        name, dynamic, creates, singleton = own
        @own_replays << [owner, method_name, name, dynamic, creates, singleton]
      end

      ShapeReader.inward_extend_shapes(node.body, parameters).each do |parameter, name, dynamic, creates|
        @inward_extends << [owner, method_name, parameter, name, dynamic, creates]
      end

      if (literal = ShapeReader.literal_replay_shape(node.body, parameters))
        call, block, singleton = literal
        @shapes.literal_replays << LiteralReplay.new(owner: owner, method: method_name, scope: @names.current_scope,
                                              call: call, block: block, source: @source, singleton: singleton)
      end

      if (delegation = ShapeReader.delegation_shape(node))
        target, callee = delegation
        @delegations << [owner, method_name, target, callee]
      end

      ShapeReader.forward_shapes(node.body, parameters).each do |parameter, callee, singleton|
        @shapes.forwards << ForwardMethod.new(owner: owner, method: method_name, parameter: parameter,
                                              callee: callee, singleton: singleton)
      end
    end

    def collect_class_body_call(node)
      return unless NodeReading.bare_or_self?(node)

      if node.block.is_a?(Prism::BlockNode)
        @shapes.stored_calls << StoredCall.new(owner: nil, subject: @names.current_scope, method: node.name.to_s,
                                        block: node.block, source: @source)
      elsif node.arguments
        # One module call per argument. `apply(A, B)` asks for A's block AND B's,
        # which is what a `*modules` forward means at runtime — each gets its
        # own candidate, and each resolves (or declines) on its own evidence.
        # Only single-argument calls used to be read at all, so the plural
        # form resolved nothing (felixefelip/rbs_infer#253).
        node.arguments.arguments.each do |argument|
          @shapes.module_calls << ModuleCall.new(owner: nil, subject: @names.current_scope, method: node.name.to_s, argument: argument)
        end
      end
    end

    # Method shapes declared OUTSIDE this file.
    #
    # The call sites stay this file's — the expander rewrites this source and
    # nothing else, so an `apply` written elsewhere would name a target this
    # rewrite cannot reach — but the DSL those calls arrive at may be declared
    # anywhere. For a reopening of a core class it always is: `Module#include`
    # is how `ActiveSupport::Concern` writes the module that supplies it, and no file that USES
    # a concern declares it (felixefelip/rbs_infer#256).
    #
    # `Corpus` decides which files those are and in what order; what to do with
    # what it finds is this method, and it is two things — keep the shapes, and
    # record the names as declared, since a name the chain reached is one this
    # file can now answer for.
    def absorb_external_shapes
      reached = Corpus.new(@sources).reach(external_lookups) do |entry|
        shapes = self.class.new(entry.source, sources: RbsInfer::Project::ConstantSources::NONE)
                     .collect_shapes(entry.result.value)
        # Read HERE, where one collector may read another's: the walk is handed
        # what to queue next rather than reaching for a protected reader.
        [shapes, shapes.external_lookups]
      end

      reached.shapes.each { |shapes| absorb(shapes) }
      @names.declare_all(reached.names)
    end

    # Every constant this file NAMES but may not declare, as
    # `[naming scope, node]`.
    #
    # `extend`'s and a superclass's, which say where the supplying module's own methods
    # come from — and the APPLY ARGUMENT, which says where the block does.
    # `include IncludedHook::Shared` names the module holding the block, and it
    # is the only mention of it in the file: without asking about it the module
    # is not in `@declarations`, so `resolve_constant` answers nil for the very
    # argument being applied and the chain ends before it starts. That is the
    # ordinary shape of a concern — declared in its own file, used from
    # another — rather than an exotic one (felixefelip/rbs_infer#265).
    def external_constants
      @names.named_constants + @shapes.module_calls.map { |module_call| [module_call.subject, module_call.argument] }
    end

    def absorb(shapes)
      @shapes.merge(shapes.shapes)
      @names.absorb(kinds: shapes.declaration_kinds, providers: shapes.providers)
    end

    # The collected `extend`s with their written constants resolved, against the
    # declarations of the file they were WRITTEN in — which is the only place
    # that name can be looked up, and the same reason `resolve_delegations` runs
    # here and again in `collect_shapes`. A dynamic name has nothing to resolve
    # yet and passes through; it is decided per call site, in `extension_name`.
    def resolve_inward_extends
      @inward_extends.filter_map do |owner, method, parameter, name, dynamic, creates|
        if dynamic
          InwardExtend.new(owner: owner, method: method, parameter: parameter, name: name, dynamic: true,
                           creates: creates)
        else
          resolved = @names.resolve(name, Declarations.lexical_context(owner))
          next unless resolved && @names.own_kind(resolved) == "module"

          InwardExtend.new(owner: owner, method: method, parameter: parameter, name: resolved, dynamic: false,
                           creates: creates)
        end
      end
    end

    # The collected own-block replays with their written constants resolved,
    # against the declarations of the file they were WRITTEN in — the same
    # two-place resolution `resolve_inward_extends` does, and for the same
    # reason. A target that is our own `self`, or a name fetched as data, has
    # nothing to resolve here: both are decided per call site.
    def resolve_own_replays
      @own_replays.filter_map do |owner, method, name, dynamic, creates, singleton|
        if name.nil? || dynamic
          OwnBlockReplay.new(owner: owner, method: method, name: name, dynamic: dynamic, creates: creates,
                             singleton: singleton)
        else
          resolved = @names.resolve(name, Declarations.lexical_context(owner))
          next unless resolved

          OwnBlockReplay.new(owner: owner, method: method, name: resolved, dynamic: false, creates: creates,
                             singleton: singleton)
        end
      end
    end

    # The collected method bodies read as deferrals, once the readers are in.
    def resolve_deferrals
      reader = DeferralReader.new(@shapes.readers)

      @deferral_shapes.filter_map do |owner, method, body, parameters|
        shape = reader.shape(body, parameters)
        next unless shape

        parameter, slot, recall = shape
        Deferral.new(owner: owner, method: method, parameter: parameter, slot: slot, recall: recall)
      end
    end

    def resolve_delegations
      @delegations.filter_map do |owner, method, raw_target, callee|
        target = @names.resolve(raw_target, owner)
        Delegation.new(owner: owner, method: method, target: target, callee: callee) if target
      end
    end

    # `attr_reader` is a normal call in a class/module body; collect it in a
    # second short lexical walk because declarations must be known before a
    # relative constant can be resolved. Keeping reader recognition explicit
    # is what prevents an arbitrary method named `body` from being treated as
    # an ivar accessor.
    def collect_readers_from_source
      parsed = Prism.parse(@source)
      reader_collector = ReaderCollector.new
      parsed.value.accept(reader_collector)
      @shapes.readers.concat(reader_collector.readers)
    end
  end
end
