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
      rbs_types = lookup_rbs_types(class_name)
      rbs_types.each { |name, type| types[name] ||= type }

      @building.delete(class_name)
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
    def lookup_rbs_types(class_name)
      types = {}
      class_path = class_name.sub(/\A::/, "").gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      Dir["sig/rbs_rails/**/*.rbs"].each do |rbs_file|
        next unless rbs_file.end_with?("#{class_path}.rbs")
        content = File.read(rbs_file)
        content.scan(/^\s*def (\w+): \(\) -> (.+)$/) do
          name, type = $1, $2
          types[name] ||= type.strip
        end
      end
      types
    end

    def find_class_file(class_name)
      class_path = class_name.sub(/\A::/, "").gsub("::", "/").gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      @source_files.find { |f| f.end_with?("#{class_path}.rb") }
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
