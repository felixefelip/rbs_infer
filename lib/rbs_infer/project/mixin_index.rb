module RbsInfer::Project
  # Resolve, para um módulo-alvo (concern), os arquivos cujas chamadas
  # *peladas* (sem receiver) podem alcançar os métodos de instância do módulo.
  #
  # Os métodos de um concern são mixados no host e chamados sem receiver — não
  # só no arquivo do próprio host, mas também nos *outros* concerns do host:
  # módulos irmãos compartilham o `self` do host, então um `track_event :x`
  # pelado em `Card::Statuses` alcança `Eventable#track_event` porque `Card`
  # inclui ambos. Esses arquivos irmãos nunca nomeiam o concern, então o índice
  # por referência de constante (`SourceIndex`) não os encontra.
  #
  # Este índice parseia cada arquivo uma vez registrando, por arquivo: a
  # classe/módulo que ele define e os short names que ele `include`/`prepend`.
  # A partir disso responde `files_reaching(module_name)` = arquivos host (que
  # incluem o módulo) ∪ os arquivos de cada módulo irmão que esses hosts também
  # incluem.
  class MixinIndex
    def initialize(source_files, parse_cache: nil)
      @parse_cache = parse_cache || ParseCache.new
      @included_shorts = {}                            # file → Set[short name]
      @files_defining = Hash.new { |h, k| h[k] = [] }  # short name → [file]
      build(source_files)
    end

    # Arquivos cujas chamadas peladas podem alcançar métodos de instância de
    # `module_name` (host + concerns irmãos do host).
    def files_reaching(module_name)
      short = module_name.split("::").last
      result = Set.new
      host_files(short).each do |host|
        result << host
        @included_shorts.fetch(host, EMPTY).each do |sibling_short|
          next if sibling_short == short
          @files_defining[sibling_short].each { |f| result << f }
        end
      end
      result.to_a
    end

    private

    EMPTY = Set.new.freeze
    private_constant :EMPTY

    # Arquivos cuja classe/módulo inclui `short`.
    def host_files(short)
      @included_shorts.filter_map { |file, shorts| file if shorts.include?(short) }
    end

    def build(source_files)
      source_files.each do |file|
        entry = @parse_cache.get(file)
        next unless entry

        extractor = RbsInfer::AST::ClassNameExtractor.new(file_path: file)
        entry.result.value.accept(extractor)
        class_name = extractor.class_name
        next unless class_name

        @files_defining[class_name.split("::").last] << file
        @included_shorts[file] = include_short_names(entry.result.value)
      end
    end

    # Short names dos argumentos de `include A, B::C` / `prepend A`.
    def include_short_names(root)
      shorts = Set.new
      RbsInfer::Analyzer.find_all_nodes(root) do |n|
        n.is_a?(Prism::CallNode) && n.receiver.nil? &&
          (n.name == :include || n.name == :prepend) && n.arguments
      end.each do |call|
        call.arguments.arguments.each do |arg|
          name = RbsInfer::Analyzer.extract_constant_path(arg)
          shorts << name.split("::").last if name
        end
      end
      shorts
    end
  end
end
