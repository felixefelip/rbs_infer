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
    @source_index = RbsInfer::Project::SourceIndex.new(source_files)
    @parse_cache = RbsInfer::Project::ParseCache.new
    @file_index = RbsInfer::Project::FileIndex.new(source_files)
    @caller_file_cache = RbsInfer::Project::CallerFileCache.new(@parse_cache)
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
        source, detect_source: original_source, path: @target_file, module_name: @target_class
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
    # @target_class — so existing output is untouched.
    if decl_targets.size <= 1 && include_targets.empty?
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
  def build_include_reopen(receiver, modules)
    members = modules.map do |mod|
      RbsInfer::Inference::Member.new(kind: :include, name: mod, signature: mod, visibility: :public, owner: nil)
    end

    RbsInfer::Signatures::RbsBuilder.new(
      target_class: receiver,
      superclass_name: nil,
      namespace_classes: resolve_namespace_classes(receiver),
      is_module: false,
      type_params: method_type_resolver.type_param_string(receiver)
    ).build(members, {}, {})
  end

  def build_single_target_rbs
    # Parsear o arquivo-alvo para extrair todos os membros da classe
    target_members = parse_target_class
    resolve_delegate_methods(target_members)

    # Extrair classes da anotação @type instance (para concerns)
    @instance_types = extract_instance_types

    # Inferir tipos do initialize via call-sites
    init_arg_types = infer_initialize_types

    # Inferir tipos dos attrs a partir do initialize (self.x = param)
    attr_types = infer_attr_types_from_initialize(init_arg_types)

    # Inferir tipos dos attrs a partir de todos os métodos da classe
    # (self.x = Foo.new ou variável local com mesmo nome do attr)
    attr_types_from_class, collection_element_types = infer_attr_types_from_class_body(target_members)
    attr_types_from_class.each do |name, type|
      attr_types[name] ||= type
    end

    # Refinar Array[untyped] usando tipos inferidos de << usage
    refine_collection_types(attr_types, collection_element_types)

    # Enriquecer init_arg_types com tipos inferidos (defaults, attrs)
    attr_types.each do |attr_name, type|
      if init_arg_types[attr_name].nil? || init_arg_types[attr_name] == "untyped"
        init_arg_types[attr_name] = type
      end
    end

    # Params com default literal `nil` aceitam nil mesmo se todos os
    # callers atuais passam não-nil — o signature precisa refletir
    # isso. Aplicado APÓS o enriquecimento pra não duplicar `?` em
    # tipos que já vieram nilable do attr_types.
    nil_default_param_names = extract_nil_default_param_names
    nil_default_param_names.each do |param_name|
      current = init_arg_types[param_name]
      next if current.nil? || current == "untyped"
      init_arg_types[param_name] = RbsInfer::Signatures::RbsParserUtil.nilablize(current)
    end

    # Resolver return types de métodos que retornam attrs conhecidos
    type_merger.resolve_method_return_types_from_attrs(target_members, attr_types, method_type_resolver: method_type_resolver, parsed_target: @parsed_target)

    # Inferir tipos de parâmetros de métodos via chamadas intra-classe
    method_param_types = param_type_inferrer.infer_method_param_types(attr_types, parsed_target: @parsed_target)

    # Inferir tipos de parâmetros de métodos via chamadas cross-class.
    # Une (não sobrescreve) com os tipos intra-classe: um método chamado com
    # `String` num arquivo e `:Symbol` noutro deve inferir `(String | Symbol)`,
    # não o primeiro tipo visto (felixefelip/rbs_infer#64).
    cross_class_param_types = infer_method_param_types_from_callers
    cross_class_param_types.each do |method_name, param_types|
      method_param_types[method_name] ||= {}
      param_types.each do |param_name, type|
        existing = method_param_types[method_name][param_name]
        method_param_types[method_name][param_name] =
          if existing && existing != "untyped"
            RbsInfer::Inference::TypeMerger.union_types([existing, type])
          else
            type
          end
      end
    end

    # Inferir tipos de instance variables (@post, @posts, etc.)
    # method_param_types feeds `@x = param` when the param's type came
    # from cross-class call-sites (felixefelip/rbs_infer#19).
    ivar_types = return_type_resolver.infer_ivar_types(target_members, attr_types, parsed_target: @parsed_target, method_param_types: method_param_types)

    # Params assigned directly to ivars (`def x=(v); @x = v; end`) accept
    # everything the ivar can hold — align `User` → `User?` when the ivar
    # is nilable (felixefelip/rbs_infer#19, mirroring the rbs_rails
    # setter convention: `(T?) -> T?`).
    widen_assigned_param_types(method_param_types, ivar_types)

    # Melhorar return types de métodos que retornam untyped usando chain resolution
    return_type_resolver.improve_method_return_types(target_members, attr_types, parsed_target: @parsed_target)

    # Second TypeMerger pass: now benefits from Steep-resolved types, inferred
    # param types and ivar types (ivar getters/setters — rbs_infer#19)
    type_merger.resolve_method_return_types_from_attrs(target_members, attr_types, method_type_resolver: method_type_resolver, parsed_target: @parsed_target, method_param_types: method_param_types, ivar_types: ivar_types)

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

    # Identificar parâmetros opcionais do initialize
    optional_params = extract_optional_init_params

    # Marker classes para cross-receiver narrowing (felixefelip/rbs_infer#11).
    # Cada setter que escreve um ivar com tipo estritamente mais
    # específico que o declarado vira uma marker nested class — Steep
    # intersecta o receiver com ela após a chamada via
    # `unconditional.self` no sidecar.
    markers = synthesize_markers(target_members, attr_types, ivar_types)

    namespace_classes = resolve_namespace_classes
    rbs_builder = RbsInfer::Signatures::RbsBuilder.new(target_class: @target_class, superclass_name: @superclass_name, namespace_classes: namespace_classes, is_module: @is_module, type_params: method_type_resolver.type_param_string(@target_class))
    rbs_builder.build(target_members, init_arg_types, attr_types, optional_params, method_param_types, ivar_types: ivar_types, markers: markers)
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
    per_method = steep_bridge.ivar_write_types_per_method(@parsed_target.source)
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

    collector = RbsInfer::AST::DefCollector.new
    @parsed_target.tree.accept(collector)

    collector.defs.each do |defn|
      param_names = def_param_names(defn)
      next if param_names.empty?

      self.class.find_all_nodes(defn) { |n| n.is_a?(Prism::InstanceVariableWriteNode) }.each do |write|
        next unless write.value.is_a?(Prism::LocalVariableReadNode)

        param_name = write.value.name.to_s
        next unless param_names.include?(param_name)

        ivar_type = ivar_types[write.name.to_s.sub(/\A@/, "")]
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
    visitor.members
  end

  def resolve_delegate_methods(target_members)
    return if @delegates.nil? || @delegates.empty?

    @delegates.each do |info|
      target_class = info.target.split("_").map(&:capitalize).join

      info.methods.each do |method_name|
        return_type = method_type_resolver.resolve(target_class, method_name) || "untyped"
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

  def infer_attr_types_from_initialize(init_arg_types)
    return {} unless @parsed_target

    visitor = RbsInfer::Inference::InitializeBodyAnalyzer.new(constant_resolver: constant_arg_resolver)
    @parsed_target.tree.accept(visitor)

    attr_types = {}

    # Mapear defaults dos keyword params: param_name -> tipo do default
    default_types = visitor.keyword_defaults
    nil_default_params = visitor.nil_default_params

    # Mapear self.attr = expr encontrados no initialize
    visitor.self_assignments.each do |attr_name, expr_info|
      type = case expr_info[:kind]
             when :param
               # self.x = x → tipo vem dos call-sites ou do default
               param_name = expr_info[:name]
               call_site_type = init_arg_types[param_name]
               call_site_type = nil if call_site_type == "untyped"
               type = call_site_type || default_types[param_name]
               # Se o param tem default literal `nil` (e.g.,
               # `def initialize(name: nil); @name = name; end`), a
               # ivar pode receber nil mesmo quando todos os callers
               # passam não-nil. Refletir isso na declaração.
               if type && nil_default_params.include?(param_name)
                 type = RbsInfer::Signatures::RbsParserUtil.nilablize(type)
               end
               type
             when :param_method
               # self.x = param.method → resolver tipo do param, depois método
               param_name = expr_info[:param_name]
               param_type = init_arg_types[param_name]
               param_type = nil if param_type.nil? || param_type == "untyped"
               if param_type
                 method_type_resolver.resolve(param_type, expr_info[:method_name])
               end
             when :call
               # self.x = algo.method → tentar resolver via RBS
               if expr_info[:class_name] && expr_info[:method_name] && method_type_resolver
                 resolved = method_type_resolver.resolve_class_method(expr_info[:class_name], expr_info[:method_name])
                 resolved == "self" ? expr_info[:class_name] : resolved
               else
                 expr_info[:type]
               end
             when :constant
               expr_info[:type]
             when :literal
               expr_info[:type]
             end

      attr_types[attr_name] = type if type
    end

    attr_types
  end

  # ─── Inferir tipos dos attrs via corpo de todos os métodos ─────────
  # Procura `self.attr = Foo.new(...)` em qualquer método da classe
  # e variáveis locais com mesmo nome de um attr_accessor.

  def infer_attr_types_from_class_body(members)
    return [{}, {}] unless @parsed_target

    attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                        .map(&:name)
                        .to_set
    return [{}, {}] if attr_names.empty?

    visitor = RbsInfer::Inference::ClassBodyAttrAnalyzer.new(attr_names: attr_names, method_type_resolver: method_type_resolver, constant_resolver: constant_arg_resolver)
    @parsed_target.tree.accept(visitor)

    [visitor.attr_types, visitor.collection_element_types]
  end

  # Refina tipos Array[untyped] com tipos de elementos inferidos via <<
  def refine_collection_types(attr_types, collection_element_types)
    collection_element_types.each do |attr_name, element_types|
      current = attr_types[attr_name]
      next unless current&.start_with?("Array[untyped]")

      element_type = element_types.to_a.join(" | ")
      attr_types[attr_name] = "Array[#{element_type}]"
    end
  end

  # ─── Inferir tipos do initialize via call-sites ────────────────────

  def infer_initialize_types
    usages = find_new_calls
    return {} if usages.empty?
    merged = type_merger.merge_argument_types(usages)
    # Se todos os tipos são untyped, tentar fallback via MethodTypeResolver
    if merged.values.all? { |t| t == "untyped" }
      fallback = method_type_resolver.resolve_init_param_types(@target_class)
      merged = fallback unless fallback.empty?
    end
    # Fallback 2: rastrear métodos wrapper em outros arquivos que chamam
    # TargetClass.new(param:, param:) com parâmetros forwarded
    if merged.values.all? { |t| t == "untyped" }
      forwarding_types = param_type_inferrer.infer_init_types_via_forwarding_wrappers
      forwarding_types.each { |k, v| merged[k] = v if merged[k] == "untyped" }
    end
    merged
  end

  def find_new_calls
    positional_params = extract_init_positional_params
    target_methods = extract_target_method_params
    analyzer = RbsInfer::Inference::CallerFileAnalyzer.new(target_class: @target_class, method_type_resolver: method_type_resolver, init_positional_params: positional_params, target_methods: target_methods, steep_bridge: steep_bridge)
    @source_index.files_referencing(@target_class).flat_map { |file| analyzer.analyze(file) }
  end

  # Inferir tipos de parâmetros de métodos via chamadas cross-class
  # Ex: PostPublisher chama notifier.notify(post.user, "msg") → user: User, message: String
  def infer_method_param_types_from_callers
    target_methods = extract_target_method_params
    return {} if target_methods.empty?

    positional_params = extract_init_positional_params
    analyzer = RbsInfer::Inference::CallerFileAnalyzer.new(
      target_class: @target_class,
      method_type_resolver: method_type_resolver,
      init_positional_params: positional_params,
      target_methods: target_methods,
      steep_bridge: steep_bridge
    )
    referencing = @source_index.files_referencing(@target_class)

    # A concern's instance methods are called *bare* by includer hosts and by
    # the host's sibling concerns — files that never name the concern, so the
    # constant-reference index misses them. For a module target, fold in the
    # mixin graph and force bare-call matching on those files (#64).
    reaching = @is_module ? mixin_index.files_reaching(@target_class).to_set : Set.new
    (referencing.to_set | reaching).each do |file|
      analyzer.analyze(file, force_bare: reaching.include?(file))
    end

    @extra_caller_sources&.call(analyzer, @target_class, @source_files)

    result = {}
    analyzer.method_call_usages.each do |method_name, usages|
      merged = type_merger.merge_argument_types(usages)
      merged.reject! { |_, t| t == "untyped" }
      result[method_name] = merged unless merged.empty?
    end
    result
  end

  # Extracts the parameter names of each target-class method
  # Returns { "notify" => ["user", "message"], ... }
  #
  # Keywords come AFTER positionals: `extract_cross_class_args` maps
  # positional args by index (which can only reach the
  # requireds+optionals prefix) and kwargs by name, so the order
  # preserves the positional mapping.
  def extract_target_method_params
    return {} unless @parsed_target

    collector = RbsInfer::AST::DefCollector.new
    @parsed_target.tree.accept(collector)

    methods = {}
    collector.defs.each do |defn|
      next if defn.name == :initialize
      params = defn.parameters
      next unless params

      names = []
      params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
      params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
      params.keywords.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:keywords)
      methods[defn.name.to_s] = names unless names.empty?
    end
    methods
  end

  # Extrai nomes dos parâmetros positional do initialize da classe-alvo
  def extract_init_positional_params
    return [] unless @parsed_target

    collector = RbsInfer::AST::DefCollector.new
    @parsed_target.tree.accept(collector)

    init_def = collector.defs.find { |d| d.name == :initialize }
    return [] unless init_def&.parameters

    params = init_def.parameters
    names = []
    params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
    params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
    names
  end

  # Returns the names of `initialize` keyword params whose default
  # value is literal `nil` — used to widen the inferred type to its
  # nilable form (`String` → `String?`) since the param can in fact
  # receive nil even if every observed call site passes non-nil.
  def extract_nil_default_param_names
    return Set.new unless @parsed_target

    visitor = RbsInfer::Inference::InitializeBodyAnalyzer.new(constant_resolver: constant_arg_resolver)
    @parsed_target.tree.accept(visitor)
    visitor.nil_default_params
  end

  def method_type_resolver
    @method_type_resolver ||= RbsInfer::Signatures::MethodTypeResolver.new(@source_files, source_index: @source_index, parse_cache: @parse_cache, file_index: @file_index, caller_file_cache: @caller_file_cache, constant_resolver: env_only_constant_resolver)
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

  def param_type_inferrer
    @param_type_inferrer ||= RbsInfer::Inference::ParamTypeInferrer.new(
      target_file: @target_file,
      target_class: @target_class,
      source_files: @source_files,
      source_index: @source_index,
      method_type_resolver: method_type_resolver,
      type_merger: type_merger,
      steep_bridge: steep_bridge,
      parse_cache: @parse_cache,
      file_index: @file_index,
      caller_file_cache: @caller_file_cache
    )
  end

  def steep_bridge
    @steep_bridge ||= RbsInfer::Signatures::SteepBridge.new
  end

  def mixin_index
    @mixin_index ||= RbsInfer::Project::MixinIndex.new(@source_files, parse_cache: @parse_cache)
  end

  # ─── Resolver quais namespaces da classe-alvo são class (não module) ──

  def resolve_namespace_classes(class_name = @target_class)
    parts = class_name.split("::")
    parts.pop

    classes = Set.new
    parts.each_index do |i|
      full_name = parts[0..i].join("::")
      class_path = RbsInfer.class_name_to_path(full_name)
      source_file = @file_index.find(class_path)

      next unless source_file && File.exist?(source_file)

      entry = @parse_cache.get(source_file)
      next unless entry

      visitor = RbsInfer::AST::ClassNameExtractor.new(file_path: source_file)
      entry.result.value.accept(visitor)
      classes.add(full_name) if visitor.class_name == full_name && !visitor.is_module
    end

    classes
  end

  end
end

require_relative "project/parse_cache"
require_relative "project/file_index"
require_relative "project/caller_file_cache"
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
require_relative "ast/def_collector"
require_relative "inference/new_call_collector"
require_relative "signatures/method_type_resolver"
require_relative "inference/caller_file_analyzer"
require_relative "signatures/rbs_builder"
require_relative "inference/constant_type_resolver"
require_relative "inference/constant_arg_type_resolver"
require_relative "inference/self_return_type_context"
require_relative "inference/type_merger"
require_relative "inference/ivar_type_set"
require_relative "inference/return_type_resolver"
require_relative "inference/param_type_inferrer"
require_relative "project/source_index"
require_relative "project/mixin_index"
require_relative "signatures/steep_bridge"
require_relative "project/source_expanders"
require_relative "project/self_type_annotators"
