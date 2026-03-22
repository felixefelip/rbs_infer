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

  def initialize(target_class: nil, source_files:, target_file: nil)
    @source_files = source_files
    @source_index = SourceIndex.new(source_files)
    @target_file = target_file
    @target_class = target_class

    if @target_file && !@target_class
      @target_class = extract_class_name_from_file(@target_file)
    elsif @target_class && !@target_file
      @target_file = find_target_file
    end
  end

  def generate_rbs
    return nil unless @target_file && @target_class && File.exist?(@target_file)

    # Parsear o arquivo-alvo uma única vez e reutilizar em todo o pipeline
    source = File.read(@target_file)
    result = Prism.parse(source)
    @parsed_target = RbsInfer::ParsedFile.new(
      result: result,
      source: source,
      comments: result.comments,
      lines: source.lines
    )

    # Parsear o arquivo-alvo para extrair todos os membros da classe
    target_members = parse_target_class

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

    # Resolver return types de métodos que retornam attrs conhecidos
    type_merger.resolve_method_return_types_from_attrs(target_members, attr_types, method_type_resolver: method_type_resolver, parsed_target: @parsed_target)

    # Inferir tipos de parâmetros de métodos via chamadas intra-classe
    method_param_types = param_type_inferrer.infer_method_param_types(attr_types, parsed_target: @parsed_target)

    # Inferir tipos de parâmetros de métodos via chamadas cross-class
    cross_class_param_types = infer_method_param_types_from_callers
    cross_class_param_types.each do |method_name, param_types|
      method_param_types[method_name] ||= {}
      param_types.each do |param_name, type|
        method_param_types[method_name][param_name] ||= type
      end
    end

    # Inferir tipos de instance variables (@post, @posts, etc.)
    ivar_types = return_type_resolver.infer_ivar_types(target_members, attr_types, parsed_target: @parsed_target)

    # Melhorar return types de métodos que retornam untyped usando chain resolution
    return_type_resolver.improve_method_return_types(target_members, attr_types, parsed_target: @parsed_target)

    # Second TypeMerger pass: now benefits from Steep-resolved types and inferred param types
    type_merger.resolve_method_return_types_from_attrs(target_members, attr_types, method_type_resolver: method_type_resolver, parsed_target: @parsed_target, method_param_types: method_param_types)

    # Identificar parâmetros opcionais do initialize
    optional_params = extract_optional_init_params

    namespace_classes = resolve_namespace_classes
    rbs_builder = RbsBuilder.new(target_class: @target_class, superclass_name: @superclass_name, namespace_classes: namespace_classes, is_module: @is_module)
    rbs_builder.build(target_members, init_arg_types, attr_types, optional_params, method_param_types, ivar_types: ivar_types)
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

  # ─── Extrair nomes dos keyword params opcionais do initialize ─────

  def extract_optional_init_params
    return Set.new unless @parsed_target

    visitor = OptionalParamExtractor.new
    @parsed_target.tree.accept(visitor)
    visitor.optional_params
  end

  # ─── Localizar arquivo da classe-alvo ──────────────────────────────

  def find_target_file
    class_path = RbsInfer.class_name_to_path(@target_class)
    @source_files.find { |f| f.end_with?("#{class_path}.rb") }
  end

  # ─── Extrair nome da classe a partir do arquivo (via Prism) ────────

  def extract_class_name_from_file(file)
    return nil unless File.exist?(file)

    result = Prism.parse(File.read(file))
    visitor = ClassNameExtractor.new
    result.value.accept(visitor)
    @is_module = visitor.is_module
    visitor.class_name
  end

  # ─── Parsear classe-alvo: métodos, attrs, visibilidade ─────────────

  def parse_target_class
    visitor = ClassMemberCollector.new(comments: @parsed_target.comments, lines: @parsed_target.lines)
    @parsed_target.tree.accept(visitor)
    @superclass_name = visitor.superclass_name
    @is_module = visitor.is_module if @is_module.nil?
    visitor.members
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

    visitor = InitializeBodyAnalyzer.new
    @parsed_target.tree.accept(visitor)

    attr_types = {}

    # Mapear defaults dos keyword params: param_name -> tipo do default
    default_types = visitor.keyword_defaults

    # Mapear self.attr = expr encontrados no initialize
    visitor.self_assignments.each do |attr_name, expr_info|
      type = case expr_info[:kind]
             when :param
               # self.x = x → tipo vem dos call-sites ou do default
               param_name = expr_info[:name]
               call_site_type = init_arg_types[param_name]
               call_site_type = nil if call_site_type == "untyped"
               call_site_type || default_types[param_name]
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

    visitor = ClassBodyAttrAnalyzer.new(attr_names: attr_names, method_type_resolver: method_type_resolver)
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
    analyzer = CallerFileAnalyzer.new(target_class: @target_class, method_type_resolver: method_type_resolver, init_positional_params: positional_params, target_methods: target_methods, steep_bridge: steep_bridge)
    @source_index.files_referencing(@target_class).flat_map { |file| analyzer.analyze(file) }
  end

  # Inferir tipos de parâmetros de métodos via chamadas cross-class
  # Ex: PostPublisher chama notifier.notify(post.user, "msg") → user: User, message: String
  def infer_method_param_types_from_callers
    target_methods = extract_target_method_params
    return {} if target_methods.empty?

    positional_params = extract_init_positional_params
    analyzer = CallerFileAnalyzer.new(
      target_class: @target_class,
      method_type_resolver: method_type_resolver,
      init_positional_params: positional_params,
      target_methods: target_methods,
      steep_bridge: steep_bridge
    )
    @source_index.files_referencing(@target_class).each { |file| analyzer.analyze(file) }

    # For helper modules, also scan ERB views as callers
    if @target_class.end_with?("Helper")
      scan_erb_views_for_helper_calls(analyzer)
    end

    result = {}
    analyzer.method_call_usages.each do |method_name, usages|
      merged = type_merger.merge_argument_types(usages)
      merged.reject! { |_, t| t == "untyped" }
      result[method_name] = merged unless merged.empty?
    end
    result
  end

  # Scan ERB views for bare helper method calls and resolve param types
  # from the view's controller ivar context.
  def scan_erb_views_for_helper_calls(analyzer)
    app_dir = detect_app_dir
    return unless app_dir

    erb_files = Dir[File.join(app_dir, "app/views/**/*.{html,turbo_stream}.erb")].sort
    return if erb_files.empty?

    # Derive controller name from helper: PostsHelper → posts
    controller_name = @target_class.sub(/Helper\z/, "").gsub("::", "/")
    controller_name = controller_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase

    erb_files.each do |erb_path|
      relative = erb_path.sub("#{app_dir}/app/views/", "")

      # Tá horrível esse código, não pode ser específico para o Rails, a gem deve ser genérica para qualquer projeto Ruby.
      # Precisa de uma forma de configurar quais arquivos analisar como callers para cada target_class, talvez via um bloco passado no initialize do Analyzer.
      # For specific helpers, only scan views from the matching controller + layouts/partials
      # ApplicationHelper applies to all views
      unless @target_class == "ApplicationHelper"
        view_controller = relative.split("/")[0..-2].join("/")
        next unless view_controller == controller_name || relative.start_with?("layouts/") || relative.include?("/_")
      end

      erb_source = File.read(erb_path)
      ruby_source = erb_to_ruby_safe(erb_source)
      next unless ruby_source

      # Build local_var_types from controller ivars
      local_var_types = erb_ivar_types(app_dir, relative)

      analyzer.analyze_source(ruby_source, local_var_types: local_var_types)
    end
  rescue => e
    # Don't let ERB scanning failures break the main analysis
    nil
  end

  def erb_to_ruby_safe(erb_source)
    require "steep/source/erb_to_ruby_code"
    Steep::Source::ErbToRubyCode.convert(erb_source.dup)
  rescue
    nil
  end

  # Resolve ivar types for an ERB view from its controller action.
  def erb_ivar_types(app_dir, view_relative)
    parts = view_relative.split("/")
    filename = parts.last.sub(/\.(html|turbo_stream)\.erb\z/, "")

    # Skip partials (start with _) — they don't have a direct controller action
    return {} if filename.start_with?("_")

    controller_parts = parts[0..-2]
    controller_name = controller_parts.join("/")
    controller_class = controller_parts.map { |p| p.split(/[_-]/).map(&:capitalize).join }.join("::") + "Controller"
    action = filename

    controller_file = Dir[File.join(app_dir, "app/controllers/#{controller_name}_controller.rb")].first
    return {} unless controller_file && File.exist?(controller_file)

    # Use Analyzer to get ivar types (cached)
    @erb_ivar_cache ||= {}
    cache_key = "#{controller_class}##{action}"
    return @erb_ivar_cache[cache_key] if @erb_ivar_cache.key?(cache_key)

    begin
      ctrl_analyzer = Analyzer.new(
        target_class: controller_class,
        target_file: controller_file,
        source_files: @source_files
      )
      rbs = ctrl_analyzer.generate_rbs
      return(@erb_ivar_cache[cache_key] = {}) unless rbs

      # Extract ivar types from generated RBS for the specific action
      ivar_types = {}
      rbs.each_line do |line|
        stripped = line.strip
        if (m = stripped.match(/\A@(\w+): (.+)\z/))
          ivar_types[m[1]] = m[2]
        end
      end
      @erb_ivar_cache[cache_key] = ivar_types
    rescue
      @erb_ivar_cache[cache_key] = {}
    end
  end

  def detect_app_dir
    # Derive app_dir from source_files (find a file matching app/controllers/*.rb)
    sample = @source_files.find { |f| f.include?("app/controllers/") }
    return nil unless sample
    idx = sample.index("app/controllers/")
    dir = sample[0...idx]
    dir.empty? ? "." : dir.chomp("/")
  end

  # Extrai nomes dos parâmetros posicionais de cada método da classe-alvo
  # Retorna { "notify" => ["user", "message"], ... }
  def extract_target_method_params
    return {} unless @parsed_target

    collector = DefCollector.new
    @parsed_target.tree.accept(collector)

    methods = {}
    collector.defs.each do |defn|
      next if defn.name == :initialize
      params = defn.parameters
      next unless params

      names = []
      params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
      params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
      methods[defn.name.to_s] = names unless names.empty?
    end
    methods
  end

  # Extrai nomes dos parâmetros positional do initialize da classe-alvo
  def extract_init_positional_params
    return [] unless @parsed_target

    collector = DefCollector.new
    @parsed_target.tree.accept(collector)

    init_def = collector.defs.find { |d| d.name == :initialize }
    return [] unless init_def&.parameters

    params = init_def.parameters
    names = []
    params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
    params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
    names
  end

  def method_type_resolver
    @method_type_resolver ||= MethodTypeResolver.new(@source_files, source_index: @source_index)
  end

  def type_merger
    @type_merger ||= TypeMerger.new(target_file: @target_file, target_class: @target_class, instance_types: @instance_types || [])
  end

  def return_type_resolver
    @return_type_resolver ||= ReturnTypeResolver.new(
      target_file: @target_file,
      target_class: @target_class,
      method_type_resolver: method_type_resolver,
      instance_types: @instance_types || [],
      steep_bridge: steep_bridge
    )
  end

  def param_type_inferrer
    @param_type_inferrer ||= ParamTypeInferrer.new(
      target_file: @target_file,
      target_class: @target_class,
      source_files: @source_files,
      source_index: @source_index,
      method_type_resolver: method_type_resolver,
      type_merger: type_merger,
      steep_bridge: steep_bridge
    )
  end

  def steep_bridge
    @steep_bridge ||= SteepBridge.new
  end

  # ─── Resolver quais namespaces da classe-alvo são class (não module) ──

  def resolve_namespace_classes
    parts = @target_class.split("::")
    parts.pop

    classes = Set.new
    parts.each_index do |i|
      full_name = parts[0..i].join("::")
      class_path = RbsInfer.class_name_to_path(full_name)
      source_file = @source_files.find { |f| f.end_with?("#{class_path}.rb") }

      next unless source_file && File.exist?(source_file)

      result = Prism.parse(File.read(source_file))
      visitor = ClassNameExtractor.new
      result.value.accept(visitor)
      classes.add(full_name) if visitor.class_name == full_name
    end

    classes
  end

  end
end

require_relative "node_type_inferrer"
require_relative "known_return_types_builder"
require_relative "rbs_annotation_parser"
require_relative "optional_param_extractor"
require_relative "class_name_extractor"
require_relative "class_body_attr_analyzer"
require_relative "intra_class_call_analyzer"
require_relative "initialize_body_analyzer"
require_relative "class_member_collector"
require_relative "def_collector"
require_relative "new_call_collector"
require_relative "method_type_resolver"
require_relative "caller_file_analyzer"
require_relative "rbs_builder"
require_relative "type_merger"
require_relative "return_type_resolver"
require_relative "param_type_inferrer"
require_relative "source_index"
require_relative "steep_bridge"
