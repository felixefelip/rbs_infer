require_relative "rbs_parser_util"

module RbsInfer
  # Busca e parseia arquivos RBS para resolver tipos de classes,
  # superclasses, módulos incluídos e herança.
  #
  # Extraído de MethodTypeResolver para manter responsabilidades separadas.

  RbsClassInfo = Data.define(:superclass, :types, :includes, :class_method_types)

  class RbsTypeLookup
    def initialize
      @inherited_cache = {}
      @rbs_collection_cache = {}
    end

    # Busca tipos em arquivos .rbs gerados (ex: rbs_rails para AR models)
    # Retorna [types_hash, superclass_name, includes_array]
    def lookup_rbs_types(class_name)
      types = {}
      superclass = nil
      all_includes = []
      normalized = class_name.sub(/\A::/, "")

      # 1. Tentar match por nome de arquivo (caso simples: uma classe por arquivo)
      class_path = RbsInfer.class_name_to_path(normalized)
      Dir["sig/**/*.rbs"].each do |rbs_file|
        next unless rbs_file.end_with?("#{class_path}.rbs")
        content = File.read(rbs_file)
        info = parse_rbs_class_block(content, normalized)
        superclass ||= info.superclass
        info.types.each { |name, type| types[name] ||= type }
        all_includes.concat(info.includes)
      end

      # 2. Buscar inner classes dentro de todos os rbs files
      if types.empty? && superclass.nil?
        Dir["sig/**/*.rbs"].each do |rbs_file|
          content = File.read(rbs_file)
          next unless content.include?(normalized.split("::").last)
          info = parse_rbs_class_block(content, normalized)
          next if info.types.empty? && info.superclass.nil? && info.includes.empty?
          superclass ||= info.superclass
          info.types.each { |name, type| types[name] ||= type }
          all_includes.concat(info.includes)
        end
      end

      return types, superclass, all_includes
    end

    # Parseia um arquivo RBS e extrai métodos, superclass e includes de uma classe específica.
    # Usa RBS::Parser para parsing correto (suporta nesting, generics, interfaces, etc).
    def parse_rbs_class_block(content, class_name)
      RbsParserUtil.class_info_from_rbs(content, class_name)
    end

    # Resolve tipos herdados percorrendo a cadeia de superclasses via RBS
    def lookup_inherited_types(superclass_name, visited = Set.new)
      return {} unless superclass_name
      normalized = superclass_name.sub(/\A::/, "")
      return {} if visited.include?(normalized)
      visited.add(normalized)

      return @inherited_cache[normalized] if @inherited_cache.key?(normalized)

      types = {}
      parent_superclass = nil
      all_includes = []

      # 1. Buscar em sig/rbs_rails/
      Dir["sig/rbs_rails/**/*.rbs"].each do |rbs_file|
        content = File.read(rbs_file)
        info = parse_rbs_class_block(content, normalized)
        parent_superclass ||= info.superclass
        info.types.each { |name, type| types[name] ||= type }
        all_includes.concat(info.includes)
      end

      # 2. Buscar em .gem_rbs_collection/
      gem_info = lookup_gem_rbs_collection_class(normalized)
      parent_superclass ||= gem_info.superclass
      gem_info.types.each { |name, type| types[name] ||= type }
      all_includes.concat(gem_info.includes)

      # 2b. Fallback: tentar removendo segmentos intermediários do namespace
      if types.empty? && parent_superclass.nil?
        parts = normalized.split("::")
        if parts.size > 2
          (parts.size - 2).downto(1) do |i|
            candidate = (parts[0...i] + [parts.last]).join("::")
            next if visited.include?(candidate)
            gem_info2 = lookup_gem_rbs_collection_class(candidate)
            if gem_info2.types.any? || gem_info2.superclass
              visited.add(candidate)
              parent_superclass ||= gem_info2.superclass
              gem_info2.types.each { |name, type| types[name] ||= type }
              all_includes.concat(gem_info2.includes)
              break
            end
          end
        end
      end

      # 3. Recursar na superclass
      if parent_superclass
        inherited = lookup_inherited_types(parent_superclass, visited)
        inherited.each { |name, type| types[name] ||= type }
      end

      # 4. Resolver módulos incluídos
      all_includes.each do |mod_name|
        mod_types = lookup_inherited_types(mod_name, visited)
        mod_types.each { |name, type| types[name] ||= type }
      end

      @inherited_cache[normalized] = types
      types
    end

    # Busca classe em .gem_rbs_collection/
    def lookup_gem_rbs_collection_class(class_name)
      types = {}
      superclass = nil
      normalized = class_name.sub(/\A::/, "")
      parts = normalized.split("::")

      gem_hints = []
      parts.first(2).each do |part|
        gem_hints << part.downcase
        gem_hints << part.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
        gem_hints << part.gsub(/([a-z])([A-Z])/, '\1-\2').downcase
      end
      gem_hints.uniq!

      rbs_files = gem_hints.flat_map { |hint| Dir[".gem_rbs_collection/#{hint}/**/*.rbs"] }.uniq
      return RbsClassInfo.new(superclass: nil, types:, includes: [], class_method_types: {}) if rbs_files.empty?

      all_includes = []
      rbs_files.each do |rbs_file|
        content = File.read(rbs_file)
        next unless content.include?(parts.last)
        info = parse_rbs_class_block(content, normalized)
        next if info.types.empty? && info.superclass.nil? && info.includes.empty?
        superclass ||= info.superclass
        info.types.each { |name, type| types[name] ||= type }
        all_includes.concat(info.includes)
      end

      RbsClassInfo.new(superclass:, types:, includes: all_includes, class_method_types: {})
    end

    # Extrai nomes de módulos incluídos via `include Foo::Bar` no source
    def extract_includes(source)
      result = Prism.parse(source)
      includes = []
      extract_include_nodes(result.value, includes)
      includes
    end

    # Busca tipos de métodos de um módulo nos arquivos RBS collection
    def lookup_rbs_collection_module_types(module_name)
      @rbs_collection_cache[module_name] ||= build_rbs_collection_module_types(module_name)
    end

    private

    def extract_include_nodes(node, includes)
      case node
      when Prism::CallNode
        if node.name == :include && node.arguments
          node.arguments.arguments.each do |arg|
            name = Analyzer.extract_constant_path(arg)
            includes << name if name
          end
        end
      end
      node.child_nodes.compact.each { |child| extract_include_nodes(child, includes) }
    end

    def build_rbs_collection_module_types(module_name)
      parts = module_name.split("::")
      first = parts.first

      gem_hints = [
        first.downcase,
        first.gsub(/([a-z])([A-Z])/, '\1_\2').downcase,
        first.gsub(/([a-z])([A-Z])/, '\1-\2').downcase,
      ].uniq

      rbs_files = gem_hints.flat_map { |hint| Dir[".gem_rbs_collection/#{hint}/**/*.rbs"] }.uniq
      return {} if rbs_files.empty?

      types = {}
      rbs_files.each do |rbs_file|
        content = File.read(rbs_file)
        next unless content.include?(parts.last)
        info = RbsParserUtil.class_info_from_rbs(content, module_name)
        info.types.each do |name, ret_type|
          parent_module = parts[0..-2].join("::")
          if ret_type !~ /::/ && ret_type =~ /\A[A-Z]/ && !parent_module.empty?
            ret_type = "#{parent_module}::#{ret_type}"
          end
          types[name] ||= ret_type
        end
      end

      types
    end
  end
end
