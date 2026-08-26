require "prism"

# Analisador que gera assinaturas RBS completas a partir de código Ruby puro,
# sem exigir anotações de tipo, comentários especiais ou arquivos extras.
# Toda a inferência é feita por análise estática do código-fonte via Prism.
#
# O objetivo é ser uma gem genérica para qualquer projeto Ruby ou Rails,
# inferindo tipos automaticamente a partir do código existente.
#
# Estratégias de inferência:
# - Tipos do initialize via call-sites (quem chama .new) e forwarding wrappers
# - Tipos de attrs via assignments no initialize (self.x = param) e corpo da classe
# - Tipos de parâmetros de métodos via chamadas intra-classe
# - Tipos de parâmetros de blocos iteradores (collection.each do |item|)
# - Return types de métodos via literais, Klass.new, method calls e method chains
# - Resolução cross-class via MethodTypeResolver (lê RBS existentes em sig/)
# - Detecção de class vs module para namespaces
# - Geração de `def self.send_mail` para subclasses de ApplicationMailer
# - Aproveitamento de anotações rbs-inline (#: e @rbs) quando presentes
#
# Uso:
#   analyzer = RbsInfer::Analyzer.new(
#     target_class: "Finance::Client::Enroll",
#     target_file: "engines/finance/app/models/finance/client/enroll.rb",
#     source_files: Dir["engines/**/*.rb", "app/**/*.rb"]
#   )
#   puts analyzer.generate_rbs
#
module RbsInfer
  class Analyzer
  ITERATOR_METHODS = RbsInfer::ITERATOR_METHODS

  attr_reader :target_class, :target_file, :source_files

  # Post-macro-expansion source (felixefelip/rbs_infer#19) — only set
  # when some expansion applied (e.g. a desugared CurrentAttributes
  # `attribute`). Exposed so the CLI can materialize the debug sidecar
  # under `sig/.../.expanded/`.
  attr_reader :expanded_source

  def initialize(target_class: nil, source_files:, target_file: nil, extra_caller_sources: nil)
    @source_files = source_files
    # Built once per file list and reused across targets: none of these can see
    # the target class, so a run over N targets was building N cold copies of
    # the same thing (RbsInfer::Project::Corpus).
    @corpus = RbsInfer::Project::Corpus.for(source_files)
    @source_index = @corpus.source_index
    @parse_cache = @corpus.parse_cache
    @file_index = @corpus.file_index
    @caller_file_cache = @corpus.caller_file_cache
    @target_file = target_file
    @target_class = target_class
    @extra_caller_sources = extra_caller_sources

    # An explicitly-supplied target_class means "generate just this one
    # class" — single-target mode, preserving the API/test contract. When
    # only a file is given (the CLI path), the analyzer is free to emit
    # every target the file defines (felixefelip/rbs_infer#38).
    @explicit_target_class = !target_class.nil?

    if @target_file && !@target_class
      @target_class = extract_class_name_from_file(@target_file)
    elsif @target_class && !@target_file
      @target_file = find_target_file
    end
  end

  def generate_rbs
    return nil unless @target_file && File.exist?(@target_file)

    load_and_parse_target

    # Single-target mode: an explicit target_class was requested, so emit
    # exactly that one declaration (API/test contract, zero churn).
    if @explicit_target_class
      return nil unless @target_class
      return build_single_target_rbs
    end

    generate_multi_target_rbs
  end

  # Parse the target file once (with macro expansion) into @parsed_target,
  # shared by the single-target pipeline and multi-target discovery.
  def load_and_parse_target
    # Parsear o arquivo-alvo uma única vez e reutilizar em todo o pipeline
    original_source = File.read(@target_file)

    # Desugar macros into plain-Ruby pseudo-code BEFORE the parse, so the
    # whole pipeline sees the expanded view (felixefelip/rbs_infer#19).
    # The pseudo-code exists only here, in memory — runtime and the app's
    # `steep check` keep reading the real source. Expanders are plugins
    # registered on RbsInfer::Project::SourceExpanders; the core knows none.
    @expanded_source = RbsInfer::Project::SourceExpanders.apply(original_source)
    source = @expanded_source || original_source

    # A block can be stored by one singleton receiver and later replayed via
    # `class_eval`/`module_eval` on another. The contextual expander moves its
    # body to that statically resolved receiver before the ordinary collector
    # attributes the `def`s to the lexical source object (rbs_infer#238).
    replay_expanded = RbsInfer::Project::StoredBlockReplayExpander.expand(source, sources: @corpus.constant_sources)
    if replay_expanded
      @expanded_source = replay_expanded
      source = replay_expanded
    end

    # Inject `@type self:`/`@type instance:` for concerns/modules (and the
    # desugared `module ClassMethods` of a `class_methods do` block) so the
    # pipeline — and Steep, as the return-type oracle — sees the right
    # self-type. Annotators are plugins registered on
    # RbsInfer::Project::SelfTypeAnnotators; the core names none
    # (felixefelip/rbs_infer#52, #60). Detection runs against the *original*
    # source so an annotator can key on a macro the expanders already desugared
    # away (`class_methods do`); the entries are injected into the expanded
    # `source` that the pipeline parses.
    if @target_class
      source = RbsInfer::Project::SelfTypeAnnotators.apply(
        source, detect_source: original_source, path: @target_file, module_name: @target_class,
        mixin_index: mixin_index
      )
    end

    result = Prism.parse(source)
    @parsed_target = RbsInfer::ParsedFile.new(
      result: result,
      source: source,
      comments: result.comments,
      lines: source.lines
    )
  end

  # A single file can define or reopen several types (initializers,
  # `lib/rails_ext/*.rb`, `on_load`/`to_prepare` blocks). Discover every
  # top-level target and emit one RBS block per target, reusing the
  # single-target pipeline for each declaration (felixefelip/rbs_infer#38).
  def generate_multi_target_rbs
    discovery = RbsInfer::AST::TargetDiscovery.new
    @parsed_target.tree.accept(discovery)
    decl_targets = discovery.declaration_targets
    include_targets = discovery.include_targets

    # The common case (one class/module, no reopen-includes) takes the
    # exact single-target path — the ClassNameExtractor pick already in
    # @target_class — so existing output is untouched. Discovering no
    # target at all means the file is a pure namespace wrapper around a
    # nested module (`class User; module Idade`), which is exactly the
    # pick the extractor makes, so that path serves it too.
    #
    # A lone target that ISN'T the extractor's pick means the extractor
    # landed elsewhere (e.g. on the `Outer` wrapper of `class Outer; class
    # Inner`, matched by basename); emitting @target_class would flatten
    # the real one, so fall through to the per-target path below.
    if include_targets.empty? && (decl_targets.empty? || (decl_targets.size == 1 && decl_targets.first[:name] == @target_class))
      return nil unless @target_class
      return build_single_target_rbs
    end

    blocks = []

    decl_targets.each do |target|
      sub = self.class.new(
        target_class: target[:name],
        target_file: @target_file,
        source_files: @source_files,
        extra_caller_sources: @extra_caller_sources
      )
      block = sub.generate_rbs
      blocks << block if block && !block.strip.empty?
    end

    include_targets.each do |receiver, modules|
      blocks << build_include_reopen(receiver, modules)
    end

    return nil if blocks.empty?

    blocks.join("\n")
  end

  # Synthesizes a reopen block for `Receiver.include Mod` call-sites: the
  # receiver has no body in this file, just the mixin. RbsBuilder handles
  # the namespace wrapping (`module ActiveStorage; module Blobs; class
  # RedirectController; include ...`).
  #
  # No body is also why it declares no nested module: `nested_modules` is
  # empty for the same reason the member list holds nothing but the mixins.
  def build_include_reopen(receiver, modules)
    members = modules.map do |mod|
      RbsInfer::Inference::Member.new(kind: :include, name: mod, signature: mod, visibility: :public, owner: nil)
    end

    RbsInfer::Signatures::RbsBuilder.new(
      target_class: receiver,
      superclass_name: nil,
      namespace_classes: resolve_namespace_classes(receiver),
      is_module: false,
      type_params: method_type_resolver.type_param_string(receiver),
      class_methods_index: class_methods_index
    ).build(members, {}, {}, ivar_types: {}, singleton_ivar_types: {}, module_ivar_types: {}, markers: [],
            nested_modules: [])
  end

  def build_single_target_rbs
    # Parsear o arquivo-alvo para extrair todos os membros da classe
    target_members = parse_target_class
    confirm_overloading!(target_members)
    resolve_delegate_methods(target_members)

    # Extrair classes da anotação @type instance (para concerns)
    @instance_types = extract_instance_types

    # Inferir tipos do initialize via call-sites
    init_arg_types = param_type_inferrer.infer_initialize_types(parsed_target: @parsed_target)

    # Attr types from everything the class's own body says: the `initialize`
    # assignments, the `self.x =` writes anywhere else, and the element types an
    # `Array[untyped]` picks up from `<<`. What only the CALLERS know is filled in
    # by `finalize`, further down — it needs the parameter types first.
    attr_types = attr_type_inferrer.infer(init_arg_types, target_members)

    # `initialize`'s own parameters gain what the attrs now know, and then the
    # ones written `= nil` widen — in that order, or the `?` doubles up on a type
    # that arrived nilable from the attrs.
    attr_type_inferrer.enrich_initialize_types(init_arg_types, attr_types)

    # Resolver return types de métodos que retornam attrs conhecidos
    type_merger.resolve_method_return_types_from_attrs(target_members, attr_types, method_type_resolver: method_type_resolver, parsed_target: @parsed_target)

    # Method parameter types, with every kind of evidence already crossed:
    # intra-class calls, forwarding wrappers, and call sites in other files. The
    # union belongs to the inferrer — a method called with `String` in one file
    # and `:symbol` in another has both types (felixefelip/rbs_infer#64).
    method_param_types = param_type_inferrer.infer_method_param_types(
      target_members, attr_types, parsed_target: @parsed_target, is_module: @is_module
    )

    # The rest of the attr types: the ones only an external `receiver.attr = value`
    # could give (its `attr=` parameter, just inferred above), and then the
    # definite-initialization `?` for every getter whose ivar `initialize` never
    # writes — applied uniformly, so a locally-typed attr follows the same rule as
    # an externally-set one (felixefelip/rbs_infer#71).
    attr_type_inferrer.finalize(attr_types, target_members, method_param_types: method_param_types)

    # Inferir tipos de instance variables (@post, @posts, etc.)
    # method_param_types feeds `@x = param` when the param's type came
    # from cross-class call-sites (felixefelip/rbs_infer#19).
    ivar_inference = return_type_resolver.infer_ivar_types(target_members, attr_types, parsed_target: @parsed_target, method_param_types: method_param_types)
    ivar_types = ivar_inference.instance
    # Class-instance variables (`@x` in `def self.x`) declared `self.@x`
    # (felixefelip/rbs_infer#86). Threaded straight to the builder — the
    # marker/widening machinery below is about instance ivars only.
    singleton_ivar_types = ivar_inference.singleton
    # Ivars a NESTED module writes belong to that module, and are DECLARED in its
    # own block — the class never had the slot (felixefelip/rbs_infer#249).
    module_ivar_types = ivar_inference.by_module

    # Where a slot is declared and what an instance may hold are two questions
    # with two answers. Declaration follows the writer, which is what the module
    # split above is for; inference wants everything reachable on an instance,
    # and a class that `include`s the module reaches the module's slots too — so
    # the passes below read the union.
    #
    # Splitting these was not optional: giving the inference passes the narrow
    # map turned every `Current` reader into `-> untyped`, because the accessors
    # live in the same nested module as the ivars they read.
    reachable_ivar_types = module_ivar_types.values.reduce(ivar_types.dup) { |all, ivars| all.merge(ivars) }

    # Params assigned directly to ivars (`def x=(v); @x = v; end`) accept
    # everything the ivar can hold — align `User` → `User?` when the ivar
    # is nilable (felixefelip/rbs_infer#19, mirroring the rbs_rails
    # setter convention: `(T?) -> T?`).
    widen_assigned_param_types(method_param_types, reachable_ivar_types)

    # Melhorar return types de métodos que retornam untyped usando chain resolution
    return_type_resolver.improve_method_return_types(target_members, attr_types, parsed_target: @parsed_target)

    # Second TypeMerger pass: now benefits from Steep-resolved types, inferred
    # param types and ivar types (ivar getters/setters — rbs_infer#19)
    type_merger.resolve_method_return_types_from_attrs(target_members, attr_types, method_type_resolver: method_type_resolver, parsed_target: @parsed_target, method_param_types: method_param_types, ivar_types: reachable_ivar_types)

    # A body with an early `return` can return nil however its tail was typed. Runs
    # AFTER every pass that sets a return type — each used to widen (or forget to) on
    # its own, so which passes a method took decided whether the `?` appeared.
    return_type_resolver.apply_early_return_nilability(target_members, parsed_target: @parsed_target)

    # Resolver tipos das constantes de classe/módulo (NOME = ...).
    # Feito aqui, no Analyzer, porque a inferência de cadeias usa o
    # SteepBridge e o new→classe-alvo precisa do target_class
    # (felixefelip/rbs_infer#37).
    resolve_constant_types(target_members)

    # Resolver tipos dos params opcionais cujo default é uma constante
    # (`def f(x = Webhook::ACTIONS)`). O collector deferiu (emitiu
    # `?untyped x`) porque o tipo é o do VALOR da constante e precisa do
    # SteepBridge/env (felixefelip/rbs_infer#46).
    resolve_constant_default_param_types(target_members, method_param_types)

    # Toda a metade "bloco" das assinaturas: os parâmetros que o corpo passa
    # (#148), a obrigatoriedade e o formato que o callee impõe (#149), o `self`
    # contra o qual um bloco guardado roda (#208) e o que os blocos dos
    # call-sites devolvem (#155). Uma reescrita só, de uma cláusula só, numa
    # ordem que o objeto é quem conhece.
    block_signature_resolver.apply(target_members, caller_returns: param_type_inferrer.caller_block_returns)

    # Identificar parâmetros opcionais do initialize
    optional_params = extract_optional_init_params

    # Marker classes para cross-receiver narrowing (felixefelip/rbs_infer#11).
    # Cada setter que escreve um ivar com tipo estritamente mais
    # específico que o declarado vira uma marker nested class — Steep
    # intersecta o receiver com ela após a chamada via
    # `unconditional.self` no sidecar.
    markers = synthesize_markers(target_members, attr_types, ivar_types)

    namespace_classes = resolve_namespace_classes
    rbs_builder = RbsInfer::Signatures::RbsBuilder.new(target_class: @target_class, superclass_name: @superclass_name, namespace_classes: namespace_classes, is_module: @is_module, type_params: method_type_resolver.type_param_string(@target_class), class_methods_index: class_methods_index)
    rbs_builder.build(target_members, init_arg_types, attr_types, optional_params, method_param_types, ivar_types: ivar_types, singleton_ivar_types: singleton_ivar_types, module_ivar_types: module_ivar_types, markers: markers, nested_modules: @nested_modules)
  end

  # Builds the marker class list to inject into the generated RBS.
  # The "declared" type for each ivar is the type the GENERATED RBS
  # will actually expose to callers via `attr_reader`/`attr_accessor`
  # — not Steep's internal wide view of all writes. If a setter's
  # narrowed type already equals what callers see by default, the
  # marker would be a no-op; only refinements add value.
  #
  # Mirrors `RbsBuilder`'s emit rule: if the member's signature
  # carries an annotation (any non-`untyped` type), use it; otherwise
  # fall back to `attr_types[name]` from the inference pipeline.
  def synthesize_markers(target_members, attr_types, _ivar_types)
    return [] unless @parsed_target && @parsed_target.source

    setter_markers = synthesize_setter_markers(target_members, attr_types)
    predicate_markers = synthesize_predicate_markers(target_members)

    merge_markers(setter_markers + predicate_markers)
  end

  def synthesize_setter_markers(target_members, attr_types)
    # Every scope whose methods can narrow an ivar on this receiver: the class
    # and the modules nested in it. Asked one by one because a scope is what
    # `ivar_write_types_per_method` takes, and since felixefelip/rbs_infer#249 it
    # answers for that scope exactly — a nested module's writers used to arrive
    # in the class's answer, and reading only the class dropped their markers
    # (`Example29::AfterBazingado`) entirely.
    #
    # Merged rather than kept apart because a marker is named for the RECEIVER,
    # and `Baz.bazingado` narrows the same object whichever scope `bazingado` is
    # written in. WHERE such a marker should be declared is the same question
    # this PR settles for ivars, one level up, and is not settled here.
    per_method = [@target_class, *target_members.filter_map(&:owner).uniq.map { |o| "#{@target_class}::#{o}" }]
                 .map { |scope| steep_bridge.ivar_write_types_per_method(@parsed_target.source, target_class: scope) }
                 .reduce({}) { |all, scoped| all.merge(scoped) { |_, a, b| a.merge(b) } }
    return [] if per_method.empty?

    declared_ivar_types = collect_declared_attr_types(target_members, attr_types)
    RbsInfer::Markers::SetterMarkerSynthesizer.synthesize(
      members: target_members,
      ivar_write_types_per_method: per_method,
      declared_ivar_types: declared_ivar_types
    )
  end

  # Reads Steep's `Postconditions::Inferrer` output directly — the
  # source-of-truth for "this predicate narrows these ivars". Keeps
  # rbs_infer's predicate-marker generation in lockstep with Steep's
  # `LogicTypeInterpreter`-driven detection.
  def synthesize_predicate_markers(target_members)
    entries = steep_bridge.postcondition_inferred_entries(@parsed_target.source)
    return [] if entries.empty?

    RbsInfer::Markers::PredicateMarkerSynthesizer.synthesize(
      inferred_entries: entries,
      target_class: @target_class,
      members: target_members
    )
  end

  # Merge markers from multiple synthesizers, deduplicating by
  # marker_name. If two synthesizers produce the same marker name
  # (a method that's both a setter and a predicate — pathological
  # but possible with `name=` / `name?` collisions stripping to the
  # same pascal), unions the overrides preserving the first emitter.
  def merge_markers(markers)
    by_name = {}
    markers.each do |marker|
      existing = by_name[marker.marker_name]
      if existing
        existing.overrides.merge!(marker.overrides) { |_key, old, _new| old }
      else
        by_name[marker.marker_name] = marker
      end
    end
    by_name.values.sort_by(&:marker_name)
  end

  def collect_declared_attr_types(target_members, attr_types)
    result = {}
    target_members.each do |m|
      next unless [:attr_reader, :attr_accessor].include?(m.kind)
      result[m.name] = emitted_attr_type_for(m, attr_types)
    end
    result
  end

  # Extracts the type the builder will actually emit for an attr
  # member, mirroring `RbsBuilder#build`'s logic.
  def emitted_attr_type_for(member, attr_types)
    sig = member.signature
    if sig.end_with?(": untyped") && attr_types[member.name]
      attr_types[member.name]
    else
      sig.split(": ", 2)[1].to_s
    end
  end

  def self.extract_constant_path(node)
    case node
    when Prism::ConstantPathNode
      parts = []
      current = node
      while current.is_a?(Prism::ConstantPathNode)
        parts.unshift(current.name.to_s)
        current = current.parent
      end
      if current.is_a?(Prism::ConstantReadNode)
        parts.unshift(current.name.to_s)
      elsif current.nil?
        parts.unshift("")
      end
      parts.join("::")
    when Prism::ConstantReadNode
      node.name.to_s
    else
      nil
    end
  end

  # Busca BFS coletando todos os nós que satisfazem o bloco
  # Compatível com Prism < 1.7 que não tem breadth_first_search_all
  def self.find_all_nodes(root, &block)
    results = []
    queue = [root]
    while (node = queue.shift)
      results << node if yield(node)
      queue.concat(node.compact_child_nodes)
    end
    results
  end

  private

  # ─── Align types of params assigned to nilable ivars ──────────────
  # For each `@y = param` in a method body: if the param's inferred type
  # is `T` and the ivar was inferred as `T?`, widen the param to `T?` —
  # assigning nil is valid (the ivar may hold nil).

  def widen_assigned_param_types(method_param_types, ivar_types)
    return if method_param_types.empty? || ivar_types.empty? || @parsed_target.nil?

    collector = RbsInfer::AST::DefCollector.new(target_class: @target_class)
    @parsed_target.tree.accept(collector)

    collector.defs.each do |defn|
      param_names = def_param_names(defn)
      next if param_names.empty?

      ivar_writes_with_values(defn).each do |ivar_name, value|
        next unless value.is_a?(Prism::LocalVariableReadNode)

        param_name = value.name.to_s
        next unless param_names.include?(param_name)

        ivar_type = ivar_types[ivar_name]
        next if ivar_type.nil? || ivar_type == "untyped"

        params = (method_param_types[defn.name.to_s] ||= {})
        current = params[param_name]
        if current.nil?
          # Untyped param whose only signal is the destination ivar —
          # inherit its type (e.g. `Current.set(user: nil)` with no
          # direct call-site).
          params[param_name] = ivar_type
        elsif ivar_type == RbsInfer::Signatures::RbsParserUtil.nilablize(current)
          params[param_name] = ivar_type
        end
      end
    end
  end

  # `[["ivar_name", value_node], ...]` for every ivar assignment in `defn`,
  # covering both `@x = v` and the multiple-assignment form `@x, @y = v, w`
  # (felixefelip/rbs_infer#183).
  def ivar_writes_with_values(defn)
    self.class.find_all_nodes(defn) do |n|
      n.is_a?(Prism::InstanceVariableWriteNode) || n.is_a?(Prism::MultiWriteNode)
    end.flat_map do |node|
      if node.is_a?(Prism::InstanceVariableWriteNode)
        [[node.name.to_s.sub(/\A@/, ""), node.value]]
      else
        RbsInfer::AST::MultiWriteDecomposer.ivar_name_pairs(node)
      end
    end
  end

  def def_param_names(defn)
    params = defn.parameters
    return [] unless params

    names = []
    params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
    params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
    params.keywords.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:keywords)
    names
  end

  # ─── Resolver tipos das constantes de classe/módulo ───────────────
  # Cada membro `:constant` carrega o nó do RHS (coletado em
  # ClassMemberCollector). O Steep tipa todos os RHS de uma vez (oráculo
  # para cadeias); o ConstantTypeResolver sobrepõe a inferência de
  # construtor (new→classe-alvo) para que o single-pass já bata com o
  # resultado convergido (felixefelip/rbs_infer#37). O tipo final é
  # gravado em `signature` como "NOME: Tipo" para o RbsBuilder emitir.

  def resolve_constant_types(target_members)
    constants = target_members.select { |m| m.kind == :constant }
    return if constants.empty?

    # Ruby's last assignment wins and RBS declares each constant once; when
    # a name is reassigned (same owner), keep only the last node and drop
    # the earlier members so the builder emits a single line.
    keep = {}
    constants.each { |m| keep[[m.owner, m.name]] = m }
    target_members.reject! { |m| m.kind == :constant && !keep[[m.owner, m.name]].equal?(m) }

    steep_types = @parsed_target&.source ? steep_bridge.constant_types(@parsed_target.source) : {}
    resolver = RbsInfer::Inference::ConstantTypeResolver.new(target_class: @target_class, constant_resolver: constant_arg_resolver)

    keep.each_value do |member|
      type = resolver.resolve(member.value_node, steep_type: steep_types[member.name])
      member.signature = "#{member.name}: #{type}"
    end
  end

  # Preenche os params opcionais com default constante que o collector deferiu
  # (`?untyped x`). Resolve via o mesmo ConstantArgTypeResolver usado para args
  # em call-sites (#46): constante-valor → tipo do valor, classe/módulo → o
  # nome (tipo válido), não resolvida → fica `untyped`. A inferência por
  # call-site, quando existe, já venceu e é preservada. Injeta em
  # `method_param_types` para o RbsBuilder substituir o `untyped`.
  # Env-aware resolver for constants-in-value-position over the TARGET source:
  # env tier (stdlib/gems/generated sig) + same-file tier (the target's own
  # constants, type-checked once). Threaded into every value-typing analyzer so
  # a constant becomes its VALUE type, never its bare name (felixefelip/rbs_infer#56).
  def constant_arg_resolver
    @constant_arg_resolver ||= RbsInfer::Inference::ConstantArgTypeResolver.new(
      steep_bridge: steep_bridge,
      caller_constant_types: @parsed_target&.source ? steep_bridge.constant_types(@parsed_target.source) : {}
    )
  end

  # Env-only variant (no same-file tier) for analyzing OTHER classes, where the
  # target's constants don't apply; their own constants resolve via generated RBS.
  def env_only_constant_resolver
    @env_only_constant_resolver ||= RbsInfer::Inference::ConstantArgTypeResolver.new(
      steep_bridge: steep_bridge, caller_constant_types: {}
    )
  end

  def resolve_constant_default_param_types(target_members, method_param_types)
    members = target_members.select do |m|
      [:method, :class_method].include?(m.kind) && m.param_constant_defaults && !m.param_constant_defaults.empty?
    end
    return if members.empty?

    resolver = constant_arg_resolver

    members.each do |member|
      member.param_constant_defaults.each do |param_name, node|
        inferred = method_param_types.dig(member.name, param_name)
        next if inferred && inferred != "untyped"

        type = resolver.resolve(name: RbsInfer::Analyzer.extract_constant_path(node), namespace: @target_class)
        next unless type

        (method_param_types[member.name] ||= {})[param_name] = type
      end
    end
  end

  # `# @rbs_infer |...` above a def asks for RBS's overloading form (`... | ...`), which
  # puts our signature AHEAD of one something else already declares instead of colliding
  # with it. The marker states intent; this confirms it, because `| ...` with nothing to
  # overload is an `InvalidOverloadMethodError` — the same class of hard failure, poisoning
  # the whole environment, that it exists to avoid. A marker on a method nobody else
  # declares silently emits the plain form rather than breaking the run.
  #
  # Our own previous output is excluded: it already declares the method, and confirming
  # against it would be circular — a method only we declare would gain `| ...` and then
  # have nothing left to overload.
  #
  # Asked of the member's OWNER, not of the target. A member in a module nested inside
  # the target belongs to `Target::Owner` (the same `#{@target_class}::#{owner}` join the
  # rest of the analyzer uses), and asking under the target's own name finds nothing —
  # which drops the marker and emits the plain form, i.e. the duplicate declaration the
  # marker is there to avoid. It fails that way silently: RBS only raises when something
  # BUILDS the class, so a collision nothing references yet sits in the environment
  # unexercised. `ActiveSupport::Concern` is a nested module in exactly that position.
  def confirm_overloading!(members)
    marked = members.select(&:overloading)
    return if marked.empty?

    own_output_suffix = @target_file&.sub(/\.rb\z/, ".rbs")

    marked.each do |member|
      owner = member.owner ? "#{@target_class}::#{member.owner}" : @target_class
      confirmed = rbs_definition_resolver.foreign_plain_declaration?(
        owner, member.name, excluding_suffix: own_output_suffix
      )
      member.overloading = false unless confirmed
    end
  end

  def rbs_definition_resolver
    @rbs_definition_resolver ||= RbsInfer::Signatures::RbsDefinitionResolver.new
  end

  # ─── Extrair nomes dos keyword params opcionais do initialize ─────

  def extract_optional_init_params
    return Set.new unless @parsed_target

    visitor = RbsInfer::AST::OptionalParamExtractor.new
    @parsed_target.tree.accept(visitor)
    visitor.optional_params
  end

  # ─── Localizar arquivo da classe-alvo ──────────────────────────────

  def find_target_file
    class_path = RbsInfer.class_name_to_path(@target_class)
    @file_index.find(class_path)
  end

  # ─── Extrair nome da classe a partir do arquivo (via Prism) ────────

  def extract_class_name_from_file(file)
    return nil unless File.exist?(file)

    entry = @parse_cache.get(file)
    return nil unless entry

    visitor = RbsInfer::AST::ClassNameExtractor.new(file_path: file)
    entry.result.value.accept(visitor)
    @is_module = visitor.is_module
    visitor.class_name
  end

  # ─── Parsear classe-alvo: métodos, attrs, visibilidade ─────────────

  def parse_target_class
    visitor = RbsInfer::Inference::ClassMemberCollector.new(comments: @parsed_target.comments, lines: @parsed_target.lines, target_class: @target_class)
    @parsed_target.tree.accept(visitor)
    @superclass_name = visitor.superclass_name
    @is_module = visitor.is_module if @is_module.nil?
    @delegates = visitor.delegates
    @nested_modules = visitor.nested_modules
    visitor.members
  end

  def resolve_delegate_methods(target_members)
    return if @delegates.nil? || @delegates.empty?

    @delegates.each do |info|
      target_class = info.target.split("_").map(&:capitalize).join

      info.methods.each do |method_name|
        return_type = method_type_resolver.resolve(target_class, method_name, arg_types: nil) || "untyped"
        return_type = RbsInfer::Signatures::RbsParserUtil.nilablize(return_type) if info.allow_nil

        generated_name = case info.prefix
                         when true   then "#{info.target}_#{method_name}"
                         when String then "#{info.prefix}_#{method_name}"
                         else             method_name
                         end

        target_members << RbsInfer::Inference::Member.new(
          kind: :method,
          name: generated_name,
          signature: "#{generated_name}: () -> #{return_type}",
          visibility: :public
        )
      end
    end
  end

  # ─── Extrair classes da anotação @type instance ────────────────────
  # Parseia comentários `# @type instance: User & User::Recoverable`
  # e retorna as classes declaradas (excluindo a própria target_class).

  def extract_instance_types
    return [] unless @parsed_target

    @parsed_target.comments.each do |comment|
      text = comment.location.slice
      if text =~ /#\s*@type\s+instance:\s*(.+)/
        types_str = $1.strip
        types = types_str.split(/\s*&\s*/).map(&:strip)
        return types.reject { |t| t == @target_class }
      end
    end

    []
  end

  # ─── Inferir tipos dos attrs via initialize ────────────────────────
  # Analisa o corpo do initialize para encontrar `self.x = param` e
  # mapeia o tipo do attr a partir do tipo do parâmetro (inferido via call-sites)
  # ou do valor default do keyword argument.

  # ─── Inferir tipos dos attrs via corpo de todos os métodos ─────────
  # Procura `self.attr = Foo.new(...)` em qualquer método da classe
  # e variáveis locais com mesmo nome de um attr_accessor.

  def method_type_resolver
    @method_type_resolver ||= RbsInfer::Signatures::MethodTypeResolver.new(@source_files, source_index: @source_index, parse_cache: @parse_cache, file_index: @file_index, caller_file_cache: @caller_file_cache, constant_resolver: env_only_constant_resolver, mixin_index: mixin_index, invoker_self_types: invoker_self_types)
  end

  # Shared by both `RbsBuilder` call-sites so a concern's file is read and
  # expanded once per analysis, not once per includer.
  def class_methods_index
    @class_methods_index ||= RbsInfer::Project::ClassMethodsIndex.new(file_index: @file_index, parse_cache: @parse_cache)
  end

  def type_merger
    @type_merger ||= RbsInfer::Inference::TypeMerger.new(target_file: @target_file, target_class: @target_class, instance_types: @instance_types || [], constant_resolver: constant_arg_resolver)
  end

  def return_type_resolver
    @return_type_resolver ||= RbsInfer::Inference::ReturnTypeResolver.new(
      target_file: @target_file,
      target_class: @target_class,
      method_type_resolver: method_type_resolver,
      constant_resolver: constant_arg_resolver,
      instance_types: @instance_types || [],
      steep_bridge: steep_bridge
    )
  end

  def block_signature_resolver
    @block_signature_resolver ||= RbsInfer::Inference::BlockSignatureResolver.new(
      parsed_target: @parsed_target,
      steep_bridge: steep_bridge
    )
  end

  def attr_type_inferrer
    @attr_type_inferrer ||= RbsInfer::Inference::AttrTypeInferrer.new(
      target_class: @target_class,
      parsed_target: @parsed_target,
      method_type_resolver: method_type_resolver,
      constant_resolver: constant_arg_resolver,
      return_type_resolver: return_type_resolver
    )
  end

  def param_type_inferrer
    @param_type_inferrer ||= RbsInfer::Inference::ParamTypeInferrer.new(
      target_file: @target_file,
      target_class: @target_class,
      source_files: @source_files,
      source_index: @source_index,
      method_type_resolver: method_type_resolver,
      type_merger: type_merger,
      mixin_index: mixin_index,
      extra_caller_sources: @extra_caller_sources,
      steep_bridge: steep_bridge,
      parse_cache: @parse_cache,
      file_index: @file_index,
      caller_file_cache: @caller_file_cache,
      invoker_self_types: invoker_self_types
    )
  end

  def steep_bridge
    @steep_bridge ||= RbsInfer::Signatures::SteepBridge.new
  end

  def mixin_index
    @corpus.mixin_index
  end

  def invoker_self_types
    @corpus.invoker_self_types
  end

  # ─── Resolver quais namespaces da classe-alvo são class (não module) ──

  def resolve_namespace_classes(class_name = @target_class)
    parts = class_name.split("::")
    parts.pop

    classes = Set.new
    own = own_file_declarations

    parts.each_index do |i|
      full_name = parts[0..i].join("::")

      # A namespace the target file declares itself is answered by that
      # declaration — no file has to be named after it. This is the normal
      # shape once nested classes are targets: `class Holder; class User` in
      # `scenario.rb` makes `Holder` the namespace of target `Holder::User`,
      # and the file-name lookup below cannot find it (there is no
      # `holder.rb`), so the wrapper would render as `module Holder` while
      # `Holder`'s own block says `class` — RBS rejects the file with
      # "Declaration of `::Holder` is duplicated".
      if own.key?(full_name)
        classes.add(full_name) unless own[full_name]
        next
      end

      # Every file whose path ends in the conventional one, not just the first:
      # a suffix is ambiguous, and the file it happens to land on may declare a
      # DIFFERENT class. `app/models/account/export.rb` (`class Account::Export`)
      # answers to "export" as much as `app/models/export.rb` does, and taking it
      # left `Export` looking undeclared — so its namespace rendered as
      # `module Export` against the `class Export` its own file declares, and RBS
      # rejected the pair with "Declaration of `::Export` is duplicated"
      # (felixefelip/rbs_infer#185).
      class_path = RbsInfer.class_name_to_path(full_name)
      @file_index.candidates(class_path).each do |source_file|
        next unless File.exist?(source_file)

        entry = @parse_cache.get(source_file)
        next unless entry

        visitor = RbsInfer::AST::ClassNameExtractor.new(file_path: source_file)
        entry.result.value.accept(visitor)
        next unless visitor.class_name == full_name

        classes.add(full_name) unless visitor.is_module
        break
      end
    end

    classes
  end

  # `{ "Holder" => false, "Holder::User" => false }` for the target file —
  # every type it declares and whether it's a module. Empty before the target
  # is parsed, and for consumers that never parse one.
  def own_file_declarations
    return {} unless @parsed_target

    @own_file_declarations ||= begin
      discovery = RbsInfer::AST::TargetDiscovery.new
      @parsed_target.tree.accept(discovery)
      discovery.declarations
    end
  end

  end
end

require_relative "project/parse_cache"
require_relative "project/file_index"
require_relative "project/class_methods_index"
require_relative "project/caller_file_cache"
require_relative "project/corpus"
require_relative "ast/lexical_constant_resolver"
require_relative "ast/multi_write_decomposer"
require_relative "ast/node_type_inferrer"
require_relative "ast/constructor_type_inferrer"
require_relative "inference/known_return_types_builder"
require_relative "signatures/rbs_annotation_parser"
require_relative "ast/optional_param_extractor"
require_relative "ast/class_name_extractor"
require_relative "ast/target_discovery"
require_relative "inference/class_body_attr_analyzer"
require_relative "inference/intra_class_call_analyzer"
require_relative "inference/initialize_body_analyzer"
require_relative "ast/lexical_scope"
require_relative "inference/class_member_collector"
require_relative "inference/class_member_collector/extract_params_signature"
require_relative "inference/class_member_collector/block_signature"
require_relative "ast/def_collector"
require_relative "inference/new_call_collector"
require_relative "inference/block_return_collector"
require_relative "inference/block_signature_resolver"
require_relative "signatures/method_type_resolver"
require_relative "inference/caller_file_analyzer"
require_relative "signatures/rbs_builder"
require_relative "inference/constant_type_resolver"
require_relative "inference/constant_arg_type_resolver"
require_relative "inference/self_return_type_context"
require_relative "inference/rest_param_marker"
require_relative "inference/method_key"
require_relative "inference/invoker_self_types"
require_relative "inference/send_call"
require_relative "inference/type_merger"
require_relative "inference/ivar_type_set"
require_relative "inference/return_type_resolver"
require_relative "inference/attr_type_inferrer"
require_relative "inference/param_type_inferrer"
require_relative "project/source_index"
require_relative "project/mixin_index"
require_relative "signatures/steep_environment"
require_relative "signatures/steep_bridge"
require_relative "signatures/steep_bridge/lexical_scope"
require_relative "signatures/steep_bridge/type_formatter"
require_relative "signatures/steep_bridge/ivar_write_analyzer"
require_relative "signatures/steep_bridge/block_analyzer"
require_relative "signatures/steep_bridge/return_type_analyzer"
require_relative "project/source_expanders"
# Core, not an extension, and registered unconditionally: `class_eval` is plain Ruby,
# so every project gets the reopen read whether or not it uses a framework.
require_relative "project/class_eval_expander"
require_relative "project/self_class_eval_expander"
# Core for the same reason: `Module.new`/`const_set` are plain Ruby, and a
# constant they fill is a declaration whatever gem is or is not present.
require_relative "project/constant_declaration_expander"
require_relative "project/self_class_eval_marker"
require_relative "project/stored_block_replay_expander"
require_relative "project/stored_block_replay_expander/reader_collector"
require_relative "project/stored_block_replay_expander/collector"
require_relative "project/stored_block_replay_implements"
require_relative "project/self_type_annotators"
