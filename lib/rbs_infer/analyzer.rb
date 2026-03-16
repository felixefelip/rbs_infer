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
  ITERATOR_METHODS = %i[each map flat_map select reject filter find detect collect each_with_object].to_set

  attr_reader :target_class, :target_file, :source_files

  def initialize(target_class: nil, source_files:, target_file: nil)
    @source_files = source_files
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

    # Parsear o arquivo-alvo para extrair todos os membros da classe
    target_members = parse_target_class

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
    type_merger.resolve_method_return_types_from_attrs(target_members, attr_types, method_type_resolver: method_type_resolver)

    # Inferir tipos de parâmetros de métodos via chamadas intra-classe
    method_param_types = infer_method_param_types(attr_types)

    # Inferir tipos de parâmetros de métodos via chamadas cross-class
    cross_class_param_types = infer_method_param_types_from_callers
    cross_class_param_types.each do |method_name, param_types|
      method_param_types[method_name] ||= {}
      param_types.each do |param_name, type|
        method_param_types[method_name][param_name] ||= type
      end
    end

    # Inferir tipos de instance variables (@post, @posts, etc.)
    ivar_types = infer_ivar_types(target_members, attr_types)

    # Melhorar return types de métodos que retornam untyped usando chain resolution
    improve_method_return_types(target_members, attr_types)

    # Identificar parâmetros opcionais do initialize
    optional_params = extract_optional_init_params

    namespace_classes = resolve_namespace_classes
    rbs_builder = RbsBuilder.new(target_class: @target_class, superclass_name: @superclass_name, namespace_classes: namespace_classes)
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
    return Set.new unless @target_file && File.exist?(@target_file)

    source = File.read(@target_file)
    result = Prism.parse(source)
    visitor = OptionalParamExtractor.new
    result.value.accept(visitor)
    visitor.optional_params
  end

  # ─── Localizar arquivo da classe-alvo ──────────────────────────────

  def find_target_file
    class_path = @target_class.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    @source_files.find { |f| f.end_with?("#{class_path}.rb") }
  end

  # ─── Extrair nome da classe a partir do arquivo (via Prism) ────────

  def extract_class_name_from_file(file)
    return nil unless File.exist?(file)

    result = Prism.parse(File.read(file))
    visitor = ClassNameExtractor.new
    result.value.accept(visitor)
    visitor.class_name
  end

  # ─── Parsear classe-alvo: métodos, attrs, visibilidade ─────────────

  def parse_target_class
    source = File.read(@target_file)
    result = Prism.parse(source)
    comments = result.comments
    lines = source.lines

    visitor = ClassMemberCollector.new(comments: comments, lines: lines)
    result.value.accept(visitor)
    @superclass_name = visitor.superclass_name
    visitor.members
  end

  # ─── Inferir tipos dos attrs via initialize ────────────────────────
  # Analisa o corpo do initialize para encontrar `self.x = param` e
  # mapeia o tipo do attr a partir do tipo do parâmetro (inferido via call-sites)
  # ou do valor default do keyword argument.

  def infer_attr_types_from_initialize(init_arg_types)
    return {} unless @target_file && File.exist?(@target_file)

    source = File.read(@target_file)
    result = Prism.parse(source)

    visitor = InitializeBodyAnalyzer.new
    result.value.accept(visitor)

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
               # self.x = algo.method → tentar resolver
               expr_info[:type]
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
    return [{}, {}] unless @target_file && File.exist?(@target_file)

    attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                        .map(&:name)
                        .to_set
    return [{}, {}] if attr_names.empty?

    source = File.read(@target_file)
    result = Prism.parse(source)

    visitor = ClassBodyAttrAnalyzer.new(attr_names: attr_names)
    result.value.accept(visitor)

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
      forwarding_types = infer_init_types_via_forwarding_wrappers
      forwarding_types.each { |k, v| merged[k] = v if merged[k] == "untyped" }
    end
    merged
  end

  def find_new_calls
    positional_params = extract_init_positional_params
    target_methods = extract_target_method_params
    analyzer = CallerFileAnalyzer.new(target_class: @target_class, method_type_resolver: method_type_resolver, init_positional_params: positional_params, target_methods: target_methods)
    @source_files.flat_map { |file| analyzer.analyze(file) }
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
      target_methods: target_methods
    )
    @source_files.each { |file| analyzer.analyze(file) }

    result = {}
    analyzer.method_call_usages.each do |method_name, usages|
      merged = type_merger.merge_argument_types(usages)
      merged.reject! { |_, t| t == "untyped" }
      result[method_name] = merged unless merged.empty?
    end
    result
  end

  # Extrai nomes dos parâmetros posicionais de cada método da classe-alvo
  # Retorna { "notify" => ["user", "message"], ... }
  def extract_target_method_params
    return {} unless @target_file && File.exist?(@target_file)

    source = File.read(@target_file)
    result = Prism.parse(source)
    collector = DefCollector.new
    result.value.accept(collector)

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
    return [] unless @target_file && File.exist?(@target_file)

    source = File.read(@target_file)
    result = Prism.parse(source)
    collector = DefCollector.new
    result.value.accept(collector)

    init_def = collector.defs.find { |d| d.name == :initialize }
    return [] unless init_def&.parameters

    params = init_def.parameters
    names = []
    params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
    params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
    names
  end

  def method_type_resolver
    @method_type_resolver ||= MethodTypeResolver.new(@source_files)
  end

  def type_merger
    @type_merger ||= TypeMerger.new(target_file: @target_file, target_class: @target_class)
  end

  # ─── Resolver quais namespaces da classe-alvo são class (não module) ──

  def resolve_namespace_classes
    parts = @target_class.split("::")
    parts.pop

    classes = Set.new
    parts.each_index do |i|
      full_name = parts[0..i].join("::")
      class_path = full_name.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      source_file = @source_files.find { |f| f.end_with?("#{class_path}.rb") }

      next unless source_file && File.exist?(source_file)

      result = Prism.parse(File.read(source_file))
      visitor = ClassNameExtractor.new
      result.value.accept(visitor)
      classes.add(full_name) if visitor.class_name == full_name
    end

    classes
  end

  # ─── Melhorar return types de métodos via chain resolution ──────

  def improve_method_return_types(members, attr_types)
    return unless @target_file && File.exist?(@target_file)

    # Métodos com return type untyped
    untyped_methods = members.select { |m| m.kind == :method && m.signature =~ /->\s*untyped$/ }
    return if untyped_methods.empty?

    source = File.read(@target_file)
    result = Prism.parse(source)

    known_return_types = {}
    attr_types.each { |name, type| known_return_types[name] = type }
    members.each do |m|
      case m.kind
      when :method
        if m.signature =~ /->\s*(.+)$/ && $1.strip != "untyped" && $1.strip != "void"
          known_return_types[m.name] = $1.strip
        end
      when :attr_accessor, :attr_reader
        if m.signature =~ /\w+:\s*(.+)/
          type = $1.strip
          known_return_types[m.name] = type unless type == "untyped"
        end
      end
    end

    if method_type_resolver
      resolver_types = method_type_resolver.resolve_all(@target_class)
      resolver_types.each { |name, type| known_return_types[name] ||= type }
    end

    # Aplicar tipos já resolvidos pelo resolver (ex: chamadas a métodos herdados)
    untyped_methods.each do |m|
      resolved = known_return_types[m.name]
      if resolved && resolved != "untyped"
        m.signature = m.signature.sub(/-> untyped$/, "-> #{resolved}")
      end
    end
    untyped_methods = members.select { |m| m.kind == :method && m.signature =~ /->\s*untyped$/ }

    untyped_names = untyped_methods.map(&:name).to_set

    collector = DefCollector.new
    result.value.accept(collector)

    collector.defs.each do |defn|
      next unless defn.is_a?(Prism::DefNode)
      next unless untyped_names.include?(defn.name.to_s)

      body = defn.body
      last_stmt = case body
                  when Prism::StatementsNode then body.body.last
                  else body
                  end
      next unless last_stmt

      resolved = infer_ivar_value_type(last_stmt, known_return_types)
      next unless resolved && resolved != "untyped"

      member = untyped_methods.find { |m| m.name == defn.name.to_s }
      member.signature = member.signature.sub(/-> untyped$/, "-> #{resolved}")
    end
  end

  # ─── Inferir tipos de instance variables (@post, @posts, etc.) ──

  def infer_ivar_types(members, attr_types)
    return {} unless @target_file && File.exist?(@target_file)

    source = File.read(@target_file)
    result = Prism.parse(source)

    # Montar known_return_types com tudo que já sabemos
    known_return_types = {}
    attr_types.each { |name, type| known_return_types[name] = type }
    members.each do |m|
      case m.kind
      when :method
        if m.signature =~ /->\s*(.+)$/ && $1.strip != "untyped" && $1.strip != "void"
          known_return_types[m.name] = $1.strip
        end
      when :attr_accessor, :attr_reader
        if m.signature =~ /\w+:\s*(.+)/
          type = $1.strip
          known_return_types[m.name] = type unless type == "untyped"
        end
      end
    end

    if method_type_resolver
      resolver_types = method_type_resolver.resolve_all(@target_class)
      resolver_types.each { |name, type| known_return_types[name] ||= type }
    end

    # Nomes de attrs já declarados (attr_accessor, attr_reader) → pular
    attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                        .map(&:name).to_set

    ivar_types = {}

    # Coletar todos os InstanceVariableWriteNode
    collector = DefCollector.new
    result.value.accept(collector)

    # Dois passes: o segundo resolve ivars que dependem de outros (@comments depende de @post)
    2.times do
      collector.defs.each do |defn|
        collect_ivar_writes(defn, known_return_types, ivar_types, attr_names)
      end
    end

    ivar_types
  end

  def collect_ivar_writes(node, known_return_types, ivar_types, attr_names)
    queue = [node]
    while (current = queue.shift)
      if current.is_a?(Prism::InstanceVariableWriteNode)
        name = current.name.to_s.sub(/\A@/, "")
        next if attr_names.include?(name)
        next if ivar_types[name] && ivar_types[name] != "untyped"

        inferred = infer_ivar_value_type(current.value, known_return_types)
        if inferred && inferred != "untyped"
          ivar_types[name] = inferred
          known_return_types[name] = inferred
        end
      end
      queue.concat(current.compact_child_nodes)
    end
  end

  def infer_ivar_value_type(node, known_return_types)
    case node
    when Prism::StringNode, Prism::InterpolatedStringNode then "String"
    when Prism::IntegerNode then "Integer"
    when Prism::FloatNode then "Float"
    when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
    when Prism::TrueNode, Prism::FalseNode then "bool"
    when Prism::ArrayNode then "Array[untyped]"
    when Prism::HashNode then "Hash[untyped, untyped]"
    when Prism::SelfNode then @target_class
    when Prism::InstanceVariableWriteNode, Prism::LocalVariableWriteNode
      infer_ivar_value_type(node.value, known_return_types)
    when Prism::CallNode
      if node.name == :new && node.receiver
        Analyzer.extract_constant_path(node.receiver)
      elsif node.receiver.nil?
        # Chamada sem receiver (self implícito): ex. posts, comments
        resolved = known_return_types[node.name.to_s]
        return resolved if resolved

        infer_block_return_type(node.block, known_return_types)
      else
        # Verificar se receiver é uma constante (chamada de classe)
        if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
          class_name = Analyzer.extract_constant_path(node.receiver)
          if class_name && method_type_resolver
            resolved = method_type_resolver.resolve_class_method(class_name, node.name.to_s)
            return (resolved == "self" ? class_name : resolved) if resolved
          end
        end

        # Chain: receiver.method → resolver tipo do receiver, depois do method
        receiver_type = resolve_chain_type(node.receiver, known_return_types)
        if receiver_type && receiver_type != "untyped"
          safe_nav = node.call_operator == "&."
          base_type = safe_nav ? receiver_type.chomp("?") : receiver_type
          resolved = resolve_on_type(base_type, node.name.to_s)
          resolved = if resolved == "self" then receiver_type
                     elsif resolved && safe_nav && !resolved.end_with?("?") then "#{resolved}?"
                     else resolved
                     end
          return resolved if resolved
        end

        # Fallback: inferir tipo do bloco (ex: transaction { ... })
        infer_block_return_type(node.block, known_return_types)
      end
    end
  end

  def infer_block_return_type(block_node, known_return_types)
    return nil unless block_node.is_a?(Prism::BlockNode)

    body = block_node.body
    last_stmt = case body
                when Prism::StatementsNode then body.body.last
                else body
                end
    return nil unless last_stmt

    infer_ivar_value_type(last_stmt, known_return_types)
  end

  # Resolve método chamado sobre um tipo conhecido
  def resolve_on_type(receiver_type, method_name)
    return nil unless method_type_resolver
    method_type_resolver.resolve(receiver_type, method_name)
  end

  def resolve_chain_type(node, known_return_types)
    case node
    when Prism::CallNode
      if node.receiver.nil?
        known_return_types[node.name.to_s]
      elsif node.name == :new && node.receiver
        Analyzer.extract_constant_path(node.receiver)
      else
        # Verificar se receiver é uma constante (chamada de classe)
        if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
          class_name = Analyzer.extract_constant_path(node.receiver)
          if class_name && method_type_resolver
            resolved = method_type_resolver.resolve_class_method(class_name, node.name.to_s)
            return (resolved == "self" ? class_name : resolved) if resolved
          end
        end

        parent_type = resolve_chain_type(node.receiver, known_return_types)
        if parent_type && parent_type != "untyped"
          safe_nav = node.call_operator == "&."
          base_type = safe_nav ? parent_type.chomp("?") : parent_type
          resolved = resolve_on_type(base_type, node.name.to_s)
          resolved = if resolved == "self" then parent_type
                     elsif resolved && safe_nav && !resolved.end_with?("?") then "#{resolved}?"
                     else resolved
                     end
          return resolved if resolved
        end

        # Fallback: inferir tipo do bloco (ex: transaction { ... })
        infer_block_return_type(node.block, known_return_types)
      end
    when Prism::SelfNode
      nil
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      Analyzer.extract_constant_path(node)
    when Prism::InstanceVariableReadNode
      known_return_types[node.name.to_s.sub(/\A@/, "")]
    end
  end

  # ─── Inferir tipos de parâmetros de métodos via chamadas intra-classe ──

  def infer_method_param_types(attr_types)
    return {} unless @target_file && File.exist?(@target_file)

    source = File.read(@target_file)
    result = Prism.parse(source)

    visitor = IntraClassCallAnalyzer.new(attr_types: attr_types, method_type_resolver: method_type_resolver)
    result.value.accept(visitor)
    inferred = visitor.inferred_param_types.dup

    # Forwarding: detectar métodos que chamam Klass.new(param:, param:)
    # com parâmetros forwarded, e inferir tipos via call-sites do método wrapper
    forwarding = detect_forwarding_methods(result)
    forwarding.each do |method_name, param_names|
      # Pular se já temos tipos inferidos (não-untyped) para este método
      if inferred[method_name]
        next unless inferred[method_name].values.all? { |t| t == "untyped" }
      end

      types = infer_wrapper_method_param_types(method_name, param_names)
      next if types.empty? || types.values.all? { |t| t == "untyped" }

      inferred[method_name] ||= {}
      types.each { |k, v| inferred[method_name][k] = v }
    end

    inferred
  end

  # Detecta métodos que fazem Klass.new(param:, param:) com parâmetros forwarded
  def detect_forwarding_methods(parse_result, target_class_filter: nil)
    forwarding = {}
    collector = DefCollector.new
    parse_result.value.accept(collector)

    collector.defs.each do |defn|
      next unless defn.parameters.is_a?(Prism::ParametersNode)

      param_names = Set.new
      defn.parameters.keywords.each { |kw| param_names << kw.name.to_s.chomp(":") } if defn.parameters.respond_to?(:keywords)
      defn.parameters.requireds.each { |p| param_names << p.name.to_s } if defn.parameters.respond_to?(:requireds)
      next if param_names.empty?

      # Procurar chamadas .new no corpo com args que são params forwarded
      body = defn.body
      next unless body

      new_calls = RbsInfer::Analyzer.find_all_nodes(body) { |n| n.is_a?(Prism::CallNode) && n.name == :new && n.receiver && n.arguments }
      new_calls.each do |node|
        if target_class_filter
          receiver_name = RbsInfer::Analyzer.extract_constant_path(node.receiver)
          next unless receiver_name
          normalized = receiver_name.sub(/\A::/, "")
          target = target_class_filter.sub(/\A::/, "")
          next unless normalized == target || target.end_with?("::#{normalized}")
        end

        forwarded_params = extract_forwarded_keyword_params(node, param_names)
        next if forwarded_params.empty?

        forwarding[defn.name.to_s] = forwarded_params
      end
    end

    forwarding
  end

  # Extrai nomes de keyword args que são forwarded de parâmetros do método
  def extract_forwarded_keyword_params(call_node, method_param_names)
    forwarded = Set.new
    call_node.arguments.arguments.each do |arg|
      next unless arg.is_a?(Prism::KeywordHashNode)

      arg.elements.each do |elem|
        next unless elem.is_a?(Prism::AssocNode)

        key = elem.key
        key_name = key.is_a?(Prism::SymbolNode) ? key.unescaped : nil
        next unless key_name

        # ImplicitNode = shorthand (ddd:) ou LocalVariableReadNode (ddd: ddd)
        value = elem.value
        value = value.value if value.is_a?(Prism::ImplicitNode)
        if value.is_a?(Prism::LocalVariableReadNode) && method_param_names.include?(value.name.to_s)
          forwarded << value.name.to_s
        end
      end
    end
    forwarded
  end

  # Rastreia métodos em OUTROS arquivos que chamam TargetClass.new(param:)
  # com parâmetros forwarded, e resolve os tipos via call-sites desses wrappers
  def infer_init_types_via_forwarding_wrappers
    types = {}
    short_name = @target_class.split("::").last

    @source_files.each do |file|
      source = File.read(file) rescue next
      next unless source.include?(short_name)

      result = Prism.parse(source)
      forwarding = detect_forwarding_methods(result, target_class_filter: @target_class)
      next if forwarding.empty?

      forwarding.each do |method_name, param_names|
        wrapper_types = infer_wrapper_method_param_types(method_name, param_names)
        wrapper_types.each { |k, v| types[k] = v if v != "untyped" }
      end
    end

    types
  end

  # Infere tipos dos parâmetros de um método via seus call-sites nos source_files
  def infer_wrapper_method_param_types(method_name, param_names)
    usages = []

    @source_files.each do |file|
      file_source = File.read(file) rescue next
      next unless file_source.include?(method_name)

      file_result = Prism.parse(file_source)
      comments = file_result.comments
      lines = file_source.lines

      # Montar method_return_types do caller
      method_return_types = {}
      member_collector = ClassMemberCollector.new(comments: comments, lines: lines)
      file_result.value.accept(member_collector)
      member_collector.members.each do |m|
        case m.kind
        when :method
          if m.signature =~ /->\s*(.+)$/
            method_return_types[m.name] = $1.strip
          end
        when :attr_accessor, :attr_reader
          if m.signature =~ /\w+:\s*(.+)/
            type = $1.strip
            method_return_types[m.name] ||= type unless type == "untyped"
          end
        end
      end

      # Resolver caller class types
      caller_ext = ClassNameExtractor.new
      file_result.value.accept(caller_ext)
      if caller_ext.class_name
        caller_types = method_type_resolver.resolve_all(caller_ext.class_name)
        caller_types.each { |name, type| method_return_types[name] ||= type }
      end

      # Procurar chamadas ao método e extrair tipos dos keyword args
      matching_calls = RbsInfer::Analyzer.find_all_nodes(file_result.value) { |n| n.is_a?(Prism::CallNode) && n.name == method_name.to_sym && n.arguments }
      matching_calls.each do |node|

        local_var_types = collect_local_var_types_for_scope(node, file_result, method_return_types, caller_ext.class_name)

        usage = {}
        node.arguments.arguments.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |elem|
            next unless elem.is_a?(Prism::AssocNode)
            key = elem.key
            key_name = key.is_a?(Prism::SymbolNode) ? key.unescaped : nil
            next unless key_name && param_names.include?(key_name)

            value = elem.value
            value = value.value if value.is_a?(Prism::ImplicitNode)
            type = resolve_arg_value_type(value, local_var_types, method_return_types)
            usage[key_name] = type
          end
        end
        usages << usage unless usage.empty?
      end
    end

    type_merger.merge_argument_types(usages)
  end

  # Resolve o tipo de um valor de argumento
  def resolve_arg_value_type(node, local_var_types, method_return_types)
    case node
    when Prism::LocalVariableReadNode
      local_var_types[node.name.to_s] || "untyped"
    when Prism::CallNode
      if node.receiver.nil?
        method_return_types[node.name.to_s] || "untyped"
      elsif node.name == :new && node.receiver
        RbsInfer::Analyzer.extract_constant_path(node.receiver) || "untyped"
      else
        # receiver.method → tentar resolver
        receiver_type = resolve_arg_value_type(node.receiver, local_var_types, method_return_types)
        if receiver_type && receiver_type != "untyped"
          method_type_resolver.resolve(receiver_type, node.name.to_s) || "untyped"
        else
          "untyped"
        end
      end
    when Prism::StringNode then "String"
    when Prism::IntegerNode then "Integer"
    when Prism::FloatNode then "Float"
    when Prism::SymbolNode then "Symbol"
    when Prism::TrueNode, Prism::FalseNode then "bool"
    when Prism::NilNode then "nil"
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      RbsInfer::Analyzer.extract_constant_path(node) || "untyped"
    when Prism::ImplicitNode
      resolve_arg_value_type(node.value, local_var_types, method_return_types)
    else
      "untyped"
    end
  end

  # Coleta tipos de variáveis locais no escopo do nó
  def collect_local_var_types_for_scope(target_node, parse_result, method_return_types, caller_class_name)
    local_var_types = {}

    # Encontrar o def encapsulante
    collector = DefCollector.new
    parse_result.value.accept(collector)

    enclosing_def = collector.defs.find do |defn|
      defn.location.start_offset <= target_node.location.start_offset &&
        defn.location.end_offset >= target_node.location.end_offset
    end

    return local_var_types unless enclosing_def

    # Resolver tipos de params do método encapsulante via call-sites do caller class
    if caller_class_name
      init_params = method_type_resolver.resolve_init_param_types(caller_class_name)
      params = enclosing_def.parameters
      if params
        params.keywords.each { |kw| name = kw.name.to_s.chomp(":"); local_var_types[name] = init_params[name] if init_params[name] } if params.respond_to?(:keywords)
        params.requireds.each { |p| name = p.name.to_s; local_var_types[name] = init_params[name] if init_params[name] } if params.respond_to?(:requireds)
      end
    end

    # Coletar assignments locais (em qualquer profundidade, antes do target_node)
    all_assignments = RbsInfer::Analyzer.find_all_nodes(enclosing_def) do |n|
      n.is_a?(Prism::LocalVariableWriteNode) &&
        n.location.start_offset < target_node.location.start_offset
    end

    # Pass 1: resolver assignments (pode não resolver os que dependem de block params)
    resolve_local_assignments(all_assignments, local_var_types, method_return_types, caller_class_name)

    # Resolver tipos de parâmetros de blocos (collection.each do |item|)
    resolve_block_param_types(enclosing_def, target_node, local_var_types, method_return_types)

    # Pass 2: re-resolver assignments que agora dependem de block params
    resolve_local_assignments(all_assignments, local_var_types, method_return_types, caller_class_name)

    local_var_types
  end

  # Resolve tipos de assignments locais
  def resolve_local_assignments(all_assignments, local_var_types, method_return_types, caller_class_name)
    all_assignments.each do |assign|
      var_name = assign.name.to_s
      next if local_var_types[var_name] && local_var_types[var_name] != "untyped"

      if assign.value.is_a?(Prism::CallNode)
        if assign.value.receiver.nil?
          method_name = assign.value.name.to_s
          local_var_types[var_name] = method_return_types[method_name] if method_return_types[method_name]
        elsif assign.value.name == :new && assign.value.receiver
          class_name = RbsInfer::Analyzer.extract_constant_path(assign.value.receiver)
          if class_name
            local_var_types[var_name] = resolve_constant_in_namespace(class_name, caller_class_name)
          end
        else
          # receiver.method → tentar resolver tipo
          if assign.value.receiver.is_a?(Prism::ConstantReadNode) || assign.value.receiver.is_a?(Prism::ConstantPathNode)
            # Chamada de classe: Record.find_by!(...) → resolver via RBS
            class_name = RbsInfer::Analyzer.extract_constant_path(assign.value.receiver)
            if class_name
              resolved = method_type_resolver.resolve_class_method(class_name, assign.value.name.to_s)
              if resolved && resolved != "untyped"
                local_var_types[var_name] = resolve_constant_in_namespace(resolved, caller_class_name)
              end
            end
          else
            receiver_type = resolve_arg_value_type(assign.value.receiver, local_var_types, method_return_types)
            if receiver_type && receiver_type != "untyped"
              resolved = method_type_resolver.resolve(receiver_type, assign.value.name.to_s)
              local_var_types[var_name] = resolved if resolved && resolved != "untyped"
            end
          end
        end
      end
    end
  end

  # Resolve tipos de parâmetros de blocos iteradores (collection.each do |item|)
  def resolve_block_param_types(enclosing_def, target_node, local_var_types, method_return_types)
    block_calls = RbsInfer::Analyzer.find_all_nodes(enclosing_def) do |n|
      n.is_a?(Prism::CallNode) && n.block.is_a?(Prism::BlockNode) &&
        ITERATOR_METHODS.include?(n.name) &&
        n.block.location.start_offset <= target_node.location.start_offset &&
        n.block.location.end_offset >= target_node.location.end_offset
    end

    block_calls.each do |call|
      block = call.block
      next unless block.parameters.is_a?(Prism::BlockParametersNode)
      next unless block.parameters.parameters

      block_param_names = []
      block.parameters.parameters.requireds&.each do |p|
        block_param_names << p.name.to_s if p.respond_to?(:name)
      end
      next if block_param_names.empty?

      # Resolver tipo da coleção (receiver do .each, .map, etc.)
      next unless call.receiver
      collection_type = resolve_arg_value_type(call.receiver, local_var_types, method_return_types)
      next if collection_type.nil? || collection_type == "untyped"

      # Extrair tipo do elemento da coleção
      element_type = extract_element_type(collection_type)
      next unless element_type

      # Primeiro block param recebe o tipo do elemento
      local_var_types[block_param_names.first] = element_type
    end
  end

  # Extrai o tipo do elemento de uma coleção
  def extract_element_type(collection_type)
    # AR CollectionProxy: Foo::Bar::ActiveRecord_Associations_CollectionProxy → Foo::Bar
    if collection_type =~ /(.+)::ActiveRecord_Associations_CollectionProxy\z/
      return $1.sub(/\A::/, "")
    end
    # Array[Type] → Type
    if collection_type =~ /\AArray\[(.+)\]\z/
      return $1
    end
    nil
  end

  # Resolve nome curto de constante no namespace do caller
  # Ex: "Record" no contexto "Academico::Aluno::Repositories::ActiveRecord::Impl"
  #     → "Academico::Aluno::Repositories::ActiveRecord::Record"
  def resolve_constant_in_namespace(short_name, context_class)
    return short_name if short_name.include?("::")
    return short_name unless context_class

    parts = context_class.split("::")
    while parts.any?
      parts.pop
      candidate = (parts + [short_name]).join("::")
      class_path = candidate.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      return candidate if @source_files.any? { |f| f.end_with?("#{class_path}.rb") }
    end

    short_name
  end
  end
end

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
