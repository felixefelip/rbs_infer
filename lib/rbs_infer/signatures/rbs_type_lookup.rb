require_relative "rbs_parser_util"

module RbsInfer::Signatures
  # Busca e parseia arquivos RBS para resolver tipos de classes,
  # superclasses, módulos incluídos e herança.
  #
  # Extraído de MethodTypeResolver para manter responsabilidades separadas.

  RbsClassInfo = Data.define(:superclass, :types, :includes, :class_method_types)

  class RbsTypeLookup
    # Run-wide caches shared across every instance. A fresh RbsTypeLookup is
    # built per Analyzer (one per file, per stabilization pass), so the old
    # per-instance caches re-globbed and re-parsed the whole `sig/` tree (768
    # .rbs in a real app) for each of ~hundreds of analyses — the dominant cost
    # once `type_check` was memoized: `RBS::Parser.parse_signature` (~10%, 94%
    # of it from here) plus `Dir.[]` (~7%), and the AST allocations driving
    # ~half the run's GC. Hoisting these to the class collapses that to ~once
    # per generation (felixefelip/rbs_infer#47).
    #
    # Only the *file-derived* data is shared (content/AST is immutable once
    # parsed); class-name-keyed inference results stay per-instance.
    class << self
      # Per-file content + parsed declarations + declaration index, keyed by
      # path and invalidated by mtime — so a sig file rewritten between
      # dependency levels is re-parsed, while unchanged files are parsed once.
      def file_entry(rbs_file)
        cache = caches[:files]
        mtime = File.mtime(rbs_file)
        entry = cache[rbs_file]
        return entry if entry && entry[:mtime] == mtime

        content = File.read(rbs_file)
        declarations = RbsParserUtil.parse_declarations(content)
        cache[rbs_file] = {
          mtime: mtime,
          content: content,
          declarations: declarations,
          index: RbsParserUtil.build_declaration_index(declarations),
        }
      rescue Errno::ENOENT, Errno::EACCES
        { mtime: nil, content: "", declarations: [], index: {} }
      end

      # Cached `Dir[...]` over `sig/`. New .rbs files appear between dependency
      # levels, so (unlike file_entry) this can't be mtime-keyed; the CLI clears
      # it via `reset!` between levels/passes. Gem-collection globs are static
      # within a run, so caching them is likewise safe.
      def glob(pattern)
        caches[:globs][pattern] ||= Dir[pattern]
      end

      # Clears the run-wide caches. Called alongside `SteepBridge.reset!`
      # between dependency levels so freshly-written sig is picked up.
      def reset!
        @caches = nil
      end

      private

      # The caches are scoped to the working directory: the sig globs and the
      # relative paths they yield only mean anything under a fixed `Dir.pwd`, so
      # a `chdir` (the CLI never does mid-run, but tests do) starts fresh —
      # mirroring `SteepBridge.definition_builder`'s dir guard.
      def caches
        dir = Dir.pwd
        if @caches.nil? || @caches[:dir] != dir
          @caches = { dir: dir, files: {}, globs: {} }
        end
        @caches
      end
    end

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
      self.class.glob("sig/**/*.rbs").each do |rbs_file|
        next unless rbs_file.end_with?("#{class_path}.rbs")
        info = class_info_from_file(rbs_file, normalized)
        superclass ||= info.superclass
        info.types.each { |name, type| types[name] ||= type }
        all_includes.concat(info.includes)
      end

      # 2. Buscar inner classes dentro de todos os rbs files
      if types.empty? && superclass.nil?
        short_name = normalized.split("::").last
        self.class.glob("sig/**/*.rbs").each do |rbs_file|
          next unless cached_content_for(rbs_file).include?(short_name)
          info = class_info_from_file(rbs_file, normalized)
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

    # Declarations RBS cacheadas para um arquivo (run-wide, ver `.file_entry`).
    def cached_declarations_for(rbs_file)
      self.class.file_entry(rbs_file)[:declarations]
    end

    # Conteúdo cacheado de um arquivo RBS (run-wide).
    def cached_content_for(rbs_file)
      self.class.file_entry(rbs_file)[:content]
    end

    # RbsClassInfo para um arquivo e classe usando o índice cacheado (O(1)).
    def class_info_from_file(rbs_file, class_name)
      RbsParserUtil.class_info_from_index(self.class.file_entry(rbs_file)[:index], class_name)
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
      self.class.glob("sig/rbs_rails/**/*.rbs").each do |rbs_file|
        info = class_info_from_file(rbs_file, normalized)
        parent_superclass ||= info.superclass
        info.types.each { |name, type| types[name] ||= type }
        all_includes.concat(info.includes)
      end

      # 1b. Demais diretórios sig/ por filename-match (módulos/shims
      #     gerados por extensions, e.g. sig/rbs_infer_devise/
      #     devise_scoped_helpers.rbs → DeviseScopedHelpers). Sem isso,
      #     tipos herdados via include desses shims ficam invisíveis
      #     (felixefelip/rbs_infer#19 follow-up: current_user do Devise).
      if types.empty? && parent_superclass.nil?
        class_path = RbsInfer.class_name_to_path(normalized)
        self.class.glob("sig/**/*.rbs").each do |rbs_file|
          next unless RbsInfer.file_matches_class_path?(rbs_file, class_path, ext: ".rbs")
          info = class_info_from_file(rbs_file, normalized)
          parent_superclass ||= info.superclass
          info.types.each { |name, type| types[name] ||= type }
          all_includes.concat(info.includes)
        end
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

      rbs_files = gem_hints.flat_map { |hint| self.class.glob(".gem_rbs_collection/#{hint}/**/*.rbs") }.uniq
      return RbsClassInfo.new(superclass: nil, types:, includes: [], class_method_types: {}) if rbs_files.empty?

      all_includes = []
      rbs_files.each do |rbs_file|
        next unless cached_content_for(rbs_file).include?(parts.last)
        info = class_info_from_file(rbs_file, normalized)
        next if info.types.empty? && info.superclass.nil? && info.includes.empty?
        superclass ||= info.superclass
        info.types.each { |name, type| types[name] ||= type }
        all_includes.concat(info.includes)
      end

      RbsClassInfo.new(superclass:, types:, includes: all_includes, class_method_types: {})
    end

    # Extrai nomes de módulos incluídos via `include Foo::Bar` no source ou AST.
    def extract_includes(source_or_node)
      node = source_or_node.is_a?(String) ? Prism.parse(source_or_node).value : source_or_node
      includes = []
      extract_include_nodes(node, includes)
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
            name = RbsInfer::Analyzer.extract_constant_path(arg)
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

      rbs_files = gem_hints.flat_map { |hint| self.class.glob(".gem_rbs_collection/#{hint}/**/*.rbs") }.uniq
      return {} if rbs_files.empty?

      types = {}
      rbs_files.each do |rbs_file|
        next unless cached_content_for(rbs_file).include?(parts.last)
        info = class_info_from_file(rbs_file, module_name)
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
