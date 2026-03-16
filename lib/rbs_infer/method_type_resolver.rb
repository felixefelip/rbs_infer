module RbsInfer
  class Analyzer
  # ─── Resolvedor de tipos inter-procedural ──────────────────────────
  # Dado um class_name e method_name, encontra o arquivo fonte da classe,
  # parseia e retorna o tipo de retorno do método.
  # Também infere tipos de attrs via keyword defaults e call-sites.

  class MethodTypeResolver
    def initialize(source_files)
      @source_files = source_files
      @cache = {}
      @building = Set.new # guard contra recursão infinita
    end

    def resolve(class_name, method_name)
      return nil unless class_name && class_name != "untyped"

      class_types = resolve_all(class_name)
      class_types[method_name] || class_types[method_name.chomp("!").chomp("?")]
    end

    # Resolve um método de classe (def self.xxx) via RBS
    def resolve_class_method(class_name, method_name)
      return nil unless class_name && class_name != "untyped"

      class_methods = lookup_class_methods(class_name)
      class_methods[method_name]
    end

    def resolve_all(class_name)
      return {} unless class_name && class_name != "untyped"
      @cache[class_name] ||= build_class_types(class_name)
    end

    # Retorna os tipos dos parâmetros do initialize inferidos via call-sites
    # Ex: Entity.new(nome: "x", email: "y") → {"nome" => "String", "email" => "String"}
    def resolve_init_param_types(class_name)
      return {} unless class_name && class_name != "untyped"
      return {} if @building_init_params&.include?(class_name)
      @init_params_cache ||= {}
      @init_params_cache[class_name] ||= build_init_param_types(class_name)
    end

    private

    def build_init_param_types(class_name)
      @building_init_params ||= Set.new
      return {} if @building_init_params.include?(class_name)
      @building_init_params.add(class_name)

      types = {}
      short_name = class_name.split("::").last
      all_usages = []

      @source_files.each do |file|
        source = File.read(file) rescue next
        next unless source.include?(short_name)

        result = Prism.parse(source)
        comments = result.comments
        lines = source.lines

        # Montar method_return_types do caller
        mrt = {}
        member_collector = RbsInfer::Analyzer::ClassMemberCollector.new(comments: comments, lines: lines)
        result.value.accept(member_collector)
        member_collector.members.each do |m|
          case m.kind
          when :method
            if m.signature =~ /->\s*(.+)$/
              mrt[m.name] = $1.strip
            end
          when :attr_accessor, :attr_reader
            if m.signature =~ /\w+:\s*(.+)/
              type = $1.strip
              mrt[m.name] ||= type unless type == "untyped"
            end
          end
        end

        # Resolver caller class types
        caller_ext = RbsInfer::Analyzer::ClassNameExtractor.new
        result.value.accept(caller_ext)
        caller_class_name = caller_ext.class_name
        if caller_class_name
          caller_types = resolve_all(caller_class_name)
          caller_types.each { |name, type| mrt[name] ||= type }
        end

        local_var_types = {}
        visitor = RbsInfer::Analyzer::NewCallCollector.new(
          target_class: class_name,
          method_return_types: mrt,
          local_var_types: local_var_types,
          method_type_resolver: self,
          caller_class_name: caller_class_name
        )
        result.value.accept(visitor)
        all_usages.concat(visitor.usages)
      end

      # Merge: preferir tipos resolvidos sobre untyped
      all_types = Hash.new { |h, k| h[k] = [] }
      all_usages.each { |u| u.each { |k, v| all_types[k] << v } }

      all_types.each do |name, ts|
        resolved = ts.reject { |t| t == "untyped" }
        resolved = ts if resolved.empty?
        unique = resolved.map { |t| t.sub(/\A::/, "") }.uniq
        types[name] = unique.size == 1 ? unique.first : "(#{unique.join(" | ")})"
      end

      @building_init_params.delete(class_name)
      types
    end

    def build_class_types(class_name)
      return {} if @building.include?(class_name)
      @building.add(class_name)

      types = {}
      file = find_class_file(class_name)

      if file && File.exist?(file)
        source = File.read(file)
        result = Prism.parse(source)
        comments = result.comments
        lines = source.lines

        # 1. Tipos anotados via ClassMemberCollector
        collector = RbsInfer::Analyzer::ClassMemberCollector.new(comments: comments, lines: lines)
        result.value.accept(collector)

        attr_names = Set.new
        collector.members.each do |member|
          case member.kind
          when :method
            if member.signature =~ /->\s*(.+)$/
              types[member.name] = $1.strip
            end
          when :attr_accessor, :attr_reader
            attr_names.add(member.name)
            if member.signature =~ /\w+:\s*(.+)/
              type = $1.strip
              types[member.name] = type unless type == "untyped"
            end
          end
        end

        # 1b. Inferir return types de literais/Klass.new na última expressão do método
        def_collector = RbsInfer::Analyzer::DefCollector.new
        result.value.accept(def_collector)
        def_collector.defs.each do |defn|
          next if types[defn.name.to_s] && types[defn.name.to_s] != "untyped"
          body = defn.body
          next unless body
          last_stmt = body.is_a?(Prism::StatementsNode) ? body.body.last : body
          next unless last_stmt

          inferred = infer_literal_return_type(last_stmt)
          types[defn.name.to_s] = inferred if inferred
        end

        # 2. Tipos inferidos via keyword defaults do initialize
        init_visitor = RbsInfer::Analyzer::InitializeBodyAnalyzer.new
        result.value.accept(init_visitor)

        init_visitor.keyword_defaults.each do |param_name, default_type|
          init_visitor.self_assignments.each do |attr_name, info|
            if info[:kind] == :param && info[:name] == param_name && !types[attr_name]
              types[attr_name] = default_type
            end
          end
        end

        # 3. Tipos inferidos via self.attr = Algo.new(...) ou constante
        init_visitor.self_assignments.each do |attr_name, info|
          next if types[attr_name]
          next unless attr_names.include?(attr_name)

          case info[:kind]
          when :constant, :call
            types[attr_name] = info[:type] if info[:type]
          end
        end

        # 4. Inferir attrs restantes via call-sites de ClassName.new(...)
        untyped_attr_params = {}
        init_visitor.self_assignments.each do |attr_name, info|
          if info[:kind] == :param && attr_names.include?(attr_name) && !types[attr_name]
            untyped_attr_params[info[:name]] = attr_name
          end
        end

        if untyped_attr_params.any?
          infer_attrs_from_call_sites(class_name, types, untyped_attr_params)
        end
      end

      # 5. Tipos de módulos incluídos (via RBS collection)
      if file && File.exist?(file)
        included_modules = extract_includes(File.read(file))
        included_modules.each do |mod_name|
          mod_types = lookup_rbs_collection_module_types(mod_name)
          mod_types.each { |name, type| types[name] ||= type }
        end
      end

      # 6. Fallback: buscar em arquivos RBS (ex: rbs_rails para AR models)
      rbs_types, rbs_superclass, rbs_includes = lookup_rbs_types(class_name)
      rbs_types.each { |name, type| types[name] ||= type }

      # 7. Resolver herança: buscar tipos da superclass e módulos incluídos
      if rbs_superclass
        inherited = lookup_inherited_types(rbs_superclass)
        inherited.each { |name, type| types[name] ||= type }
      end

      rbs_includes.each do |mod_name|
        mod_types = lookup_inherited_types(mod_name)
        mod_types.each { |name, type| types[name] ||= type }
      end if rbs_includes&.any?

      @building.delete(class_name)
      types
    end

    # Busca métodos de classe (def self.xxx) em arquivos RBS
    def lookup_class_methods(class_name)
      @class_method_cache ||= {}
      return @class_method_cache[class_name] if @class_method_cache.key?(class_name)

      types = {}
      normalized = class_name.sub(/\A::/, "")

      Dir["sig/**/*.rbs"].each do |rbs_file|
        content = File.read(rbs_file)
        next unless content.include?(normalized.split("::").last)
        _, _, _, class_ts = parse_rbs_class_block(content, normalized)
        class_ts.each { |name, type| types[name] ||= type }
      end

      @class_method_cache[class_name] = types
      types
    end

    # Escaneia source files para encontrar ClassName.new(key: val)
    # e inferir os tipos dos kwargs → attrs
    def infer_attrs_from_call_sites(class_name, types, param_to_attr)
      short_name = class_name.split("::").last

      @source_files.each do |file|
        source = File.read(file) rescue next
        next unless source.include?(short_name)

        result = Prism.parse(source)
        comments = result.comments
        lines = source.lines

        # Extrair tipos de métodos e attrs anotados do caller
        method_return_types = {}
        def_visitor = RbsInfer::Analyzer::DefCollector.new
        result.value.accept(def_visitor)
        def_visitor.defs.each do |defn|
          def_line = defn.location.start_line
          comments.each do |comment|
            cl = comment.location.start_line
            next unless cl.between?(def_line - 3, def_line - 1)
            text = comment.location.slice
            if text =~ /#:\s*(?:\(.*?\)\s*)?->\s*(.+)/
              method_return_types[defn.name.to_s] = $1.strip
            end
          end
        end

        # Incluir attr types anotados
        member_collector = RbsInfer::Analyzer::ClassMemberCollector.new(comments: comments, lines: lines)
        result.value.accept(member_collector)
        member_collector.members.each do |m|
          next unless [:attr_accessor, :attr_reader].include?(m.kind)
          if m.signature =~ /\w+:\s*(.+)/
            type = $1.strip
            method_return_types[m.name] ||= type unless type == "untyped"
          end
        end

        # Resolver caller class types via MethodTypeResolver
        caller_ext = RbsInfer::Analyzer::ClassNameExtractor.new
        result.value.accept(caller_ext)
        caller_class_name = caller_ext.class_name
        if caller_class_name
          caller_types = resolve_all(caller_class_name)
          caller_types.each { |name, type| method_return_types[name] ||= type }
        end

        local_var_types = {}
        visitor = RbsInfer::Analyzer::NewCallCollector.new(
          target_class: class_name,
          method_return_types: method_return_types,
          local_var_types: local_var_types,
          method_type_resolver: self,
          caller_class_name: caller_class_name
        )
        result.value.accept(visitor)

        visitor.usages.each do |usage|
          usage.each do |param_name, type|
            if param_to_attr.key?(param_name) && type != "untyped"
              attr_name = param_to_attr[param_name]
              types[attr_name] ||= type
            end
          end
        end
      end
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
    # Retorna [superclass, types, includes]
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
            # Nome absoluto: substituir todo o nesting
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
            # Qualificar superclass relativa usando o namespace do nesting
            if parent && !parent.start_with?("::")
              ns = nesting[0..-2] # namespace sem a própria classe
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
          # Extrair definições de método dentro da classe alvo
          if stripped =~ /\Adef self\.(\w+[\?\!]?)\s*:/
            method_name = $1
            if stripped =~ /\)\s*->\s*(\S+)\s*$/
              class_method_types[method_name] ||= $1.strip
            elsif stripped =~ /->\s*(\S+)\s*$/
              class_method_types[method_name] ||= $1.strip
            end
          elsif stripped =~ /\Adef (\w+[\?\!]?)\s*:/
            method_name = $1
            # Extrair return type: último -> na linha (ignora blocos como { () -> untyped })
            if stripped =~ /\)\s*->\s*(\S+)\s*$/
              types[method_name] ||= $1.strip
            elsif stripped =~ /->\s*(\S+)\s*$/
              types[method_name] ||= $1.strip
            end
          elsif stripped =~ /\Ainclude\s+(\S+)/
            mod_name = $1.sub(/\[.*\z/, "") # Strip type parameters
            # Qualificar nome relativo usando o namespace da classe
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
    # Busca em sig/rbs_rails/ e .gem_rbs_collection/
    # Suporta fallback de resolução de nomes (ex: ActiveRecord::Associations::Relation → ActiveRecord::Relation)
    def lookup_inherited_types(superclass_name, visited = Set.new)
      return {} unless superclass_name
      normalized = superclass_name.sub(/\A::/, "")
      return {} if visited.include?(normalized)
      visited.add(normalized)

      @inherited_cache ||= {}
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

      # 2b. Fallback: se o nome pode ser um nome qualificado incorretamente,
      #     tentar removendo segmentos intermediários do namespace
      #     ex: ActiveRecord::Associations::Relation → ActiveRecord::Relation
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

    # Busca classe em .gem_rbs_collection/ (superclasses, modules incluídos)
    def lookup_gem_rbs_collection_class(class_name)
      types = {}
      superclass = nil
      normalized = class_name.sub(/\A::/, "")
      parts = normalized.split("::")

      # Derivar possíveis nomes de gem a partir do namespace
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

    def find_class_file(class_name)
      class_path = class_name.sub(/\A::/, "").gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      @source_files.find { |f| f.end_with?("#{class_path}.rb") }
    end

    # Inferir return type a partir de literais ou Klass.new na última expressão
    def infer_literal_return_type(node)
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::NilNode then "nil"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then "Hash[untyped, untyped]"
      when Prism::CallNode
        if node.name == :new && node.receiver
          RbsInfer::Analyzer.extract_constant_path(node.receiver)
        end
      end
    end

    # Extrai nomes de módulos incluídos via `include Foo::Bar` no source
    def extract_includes(source)
      result = Prism.parse(source)
      includes = []
      extract_include_nodes(result.value, includes)
      includes
    end

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

    # Busca tipos de métodos de um módulo nos arquivos RBS collection
    def lookup_rbs_collection_module_types(module_name)
      @rbs_collection_cache ||= {}
      @rbs_collection_cache[module_name] ||= build_rbs_collection_module_types(module_name)
    end

    def build_rbs_collection_module_types(module_name)
      types = {}
      parts = module_name.split("::")
      first = parts.first

      # Tentar vários padrões de nome de gem
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
            # Qualificar tipos relativos (ex: Errors → ActiveModel::Errors)
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
