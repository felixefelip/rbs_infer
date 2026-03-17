module RbsInfer
  class Analyzer
  # Busca e parseia arquivos RBS para resolver tipos de classes,
  # superclasses, módulos incluídos e herança.
  #
  # Extraído de MethodTypeResolver para manter responsabilidades separadas.

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
      class_path = normalized.gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      Dir["sig/**/*.rbs"].each do |rbs_file|
        next unless rbs_file.end_with?("#{class_path}.rbs")
        content = File.read(rbs_file)
        sc, ts, incs = parse_rbs_class_block(content, normalized)
        superclass ||= sc
        ts.each { |name, type| types[name] ||= type }
        all_includes.concat(incs)
      end

      # 2. Buscar inner classes dentro de todos os rbs files
      if types.empty? && superclass.nil?
        Dir["sig/**/*.rbs"].each do |rbs_file|
          content = File.read(rbs_file)
          next unless content.include?(normalized.split("::").last)
          sc, ts, incs = parse_rbs_class_block(content, normalized)
          next if ts.empty? && sc.nil? && incs.empty?
          superclass ||= sc
          ts.each { |name, type| types[name] ||= type }
          all_includes.concat(incs)
        end
      end

      return types, superclass, all_includes
    end

    # Parseia um arquivo RBS e extrai métodos, superclass e includes de uma classe específica.
    # Suporta nesting (module A / module B / class C) e nomes inline (class A::B::C).
    # Nomes com :: prefix (class ::Foo::Bar) são absolutos e resetam o nesting.
    # Retorna [superclass, types, includes, class_method_types]
    def parse_rbs_class_block(content, class_name)
      types = {}
      class_method_types = {}
      superclass = nil
      includes = []
      normalized = class_name.sub(/\A::/, "")

      nesting = []       # stack de nomes de namespace (fully-qualified)
      nesting_sizes = [] # quantos segmentos cada module/class pusharam
      in_target = false
      target_depth = nil

      content.lines.each do |line|
        stripped = line.strip

        if stripped =~ /\A(module|class)\s+(::)?([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)(?:\s*<\s*(\S+))?\s*$/
          is_absolute = !!$2
          name_parts = $3.split("::")
          parent = $4

          if is_absolute
            saved_nesting = nesting.dup
            saved_sizes = nesting_sizes.dup
            nesting.replace(name_parts)
            nesting_sizes << { absolute: true, parts: name_parts.size, prev_nesting: saved_nesting, prev_sizes: saved_sizes }
          else
            nesting.concat(name_parts)
            nesting_sizes << { absolute: false, parts: name_parts.size }
          end

          fqn = nesting.join("::")

          if !in_target && fqn == normalized
            in_target = true
            target_depth = nesting.size
            if parent && !parent.start_with?("::")
              ns = nesting[0..-2]
              superclass = parent.include?("::") ? parent : (ns + [parent]).join("::") if ns.any?
              superclass ||= parent
            else
              superclass = parent&.sub(/\A::/, "")
            end
          end
        elsif stripped == "end"
          if in_target && nesting.size == target_depth
            in_target = false
            target_depth = nil
          end
          info = nesting_sizes.pop
          if info
            if info[:absolute]
              nesting.replace(info[:prev_nesting])
              nesting_sizes.replace(info[:prev_sizes])
            else
              info[:parts].times { nesting.pop }
            end
          end
        elsif in_target && nesting.size == target_depth
          if stripped =~ /\Adef self\.(\w+[\?\!]?)\s*:/
            method_name = $1
            if stripped =~ /\)\s*->\s*(\S+)\s*$/
              class_method_types[method_name] ||= $1.strip
            elsif stripped =~ /->\s*(\S+)\s*$/
              class_method_types[method_name] ||= $1.strip
            end
          elsif stripped =~ /\Adef (\w+[\?\!]?)\s*:/
            method_name = $1
            if stripped =~ /\)\s*->\s*(\S+)\s*$/
              types[method_name] ||= $1.strip
            elsif stripped =~ /->\s*(\S+)\s*$/
              types[method_name] ||= $1.strip
            end
          elsif stripped =~ /\Ainclude\s+(\S+)/
            mod_name = $1.sub(/\[.*\z/, "")
            if mod_name !~ /::/
              parent_ns = normalized.split("::")[0..-2]
              mod_name = (parent_ns + [mod_name]).join("::") if parent_ns.any?
            elsif mod_name.start_with?("::")
              mod_name = mod_name.sub(/\A::/, "")
            end
            includes << mod_name
          elsif stripped =~ /\Aattr_(reader|accessor|writer)\s+(\w+)\s*:\s*(.+)/
            attr_name = $2
            attr_type = $3.strip
            types[attr_name] ||= attr_type unless attr_type == "untyped"
          end
        end
      end

      [superclass, types, includes, class_method_types]
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
        sc, ts, incs = parse_rbs_class_block(content, normalized)
        parent_superclass ||= sc
        ts.each { |name, type| types[name] ||= type }
        all_includes.concat(incs)
      end

      # 2. Buscar em .gem_rbs_collection/
      gem_sc, gem_ts, gem_incs = lookup_gem_rbs_collection_class(normalized)
      parent_superclass ||= gem_sc
      gem_ts.each { |name, type| types[name] ||= type }
      all_includes.concat(gem_incs) if gem_incs

      # 2b. Fallback: tentar removendo segmentos intermediários do namespace
      if types.empty? && parent_superclass.nil?
        parts = normalized.split("::")
        if parts.size > 2
          (parts.size - 2).downto(1) do |i|
            candidate = (parts[0...i] + [parts.last]).join("::")
            next if visited.include?(candidate)
            gem_sc2, gem_ts2, gem_incs2 = lookup_gem_rbs_collection_class(candidate)
            if gem_ts2.any? || gem_sc2
              visited.add(candidate)
              parent_superclass ||= gem_sc2
              gem_ts2.each { |name, type| types[name] ||= type }
              all_includes.concat(gem_incs2) if gem_incs2
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
      return [nil, types] if rbs_files.empty?

      all_includes = []
      rbs_files.each do |rbs_file|
        content = File.read(rbs_file)
        next unless content.include?(parts.last)
        sc, ts, incs = parse_rbs_class_block(content, normalized)
        next if ts.empty? && sc.nil? && incs.empty?
        superclass ||= sc
        ts.each { |name, type| types[name] ||= type }
        all_includes.concat(incs)
      end

      [superclass, types, all_includes]
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
      types = {}
      parts = module_name.split("::")
      first = parts.first

      gem_hints = [
        first.downcase,
        first.gsub(/([a-z])([A-Z])/, '\1_\2').downcase,
        first.gsub(/([a-z])([A-Z])/, '\1-\2').downcase,
      ].uniq

      rbs_files = gem_hints.flat_map { |hint| Dir[".gem_rbs_collection/#{hint}/**/*.rbs"] }.uniq
      return types if rbs_files.empty?

      content = rbs_files.map { |f| File.read(f) }.join("\n")
      target_suffix = parts[1..].join("::")

      nesting = []
      target_depth = nil

      content.lines.each do |line|
        stripped = line.strip

        if stripped =~ /\A(module|class)\s+(\S+)/
          nesting << $2
          if target_depth.nil? && nesting.join("::").end_with?(target_suffix)
            target_depth = nesting.size
          end
        elsif stripped == "end"
          target_depth = nil if target_depth && nesting.size == target_depth
          nesting.pop if nesting.any?
        elsif target_depth && nesting.size == target_depth && stripped =~ /\Adef (\w+[\?\!]?)\s*:\s*(.+)/
          method_name = $1
          signature = $2
          if signature =~ /->\s*(.+)\z/
            ret_type = $1.strip
            parent_module = parts[0..-2].join("::")
            if ret_type !~ /::/ && ret_type =~ /\A[A-Z]/
              ret_type = "#{parent_module}::#{ret_type}"
            end
            types[method_name] = ret_type
          end
        end
      end

      types
    end
  end
  end
end
