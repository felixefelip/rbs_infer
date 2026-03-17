module RbsInfer
  class Analyzer
  # ─── Resolvedor de tipos inter-procedural ──────────────────────────
  # Dado um class_name e method_name, encontra o arquivo fonte da classe,
  # parseia e retorna o tipo de retorno do método.
  # Também infere tipos de attrs via keyword defaults e call-sites.

  class MethodTypeResolver
    include NodeTypeInferrer

    def initialize(source_files, source_index: nil)
      @source_files = source_files
      @source_index = source_index
      @cache = {}
      @building = Set.new # guard contra recursão infinita
      @rbs_type_lookup = RbsTypeLookup.new
      @rbs_definition_resolver = RbsDefinitionResolver.new
    end

    def resolve(class_name, method_name)
      return nil unless class_name && class_name != "untyped"

      # Tentar via RBS DefinitionBuilder primeiro (resolve genéricos corretamente)
      rbs_result = @rbs_definition_resolver.resolve_via_rbs_builder(:instance, class_name, method_name)
      return rbs_result if rbs_result && rbs_result != "untyped"

      # Fallback: source + regex-based resolution
      class_types = resolve_all(class_name)
      class_types[method_name] || class_types[method_name.delete_suffix("!").delete_suffix("?")]
    end

    # Resolve um método de classe (def self.xxx) via RBS
    def resolve_class_method(class_name, method_name)
      return nil unless class_name && class_name != "untyped"

      # Tentar via RBS DefinitionBuilder primeiro (resolve genéricos corretamente)
      resolved = @rbs_definition_resolver.resolve_via_rbs_builder(:singleton, class_name, method_name)
      return resolved if resolved

      # Fallback: regex-based lookup
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

      files = @source_index ? @source_index.files_referencing(class_name) : @source_files
      files.each do |file|
        begin
          source = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
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

          inferred = infer_literal_return_type(last_stmt, class_name)
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
        included_modules = @rbs_type_lookup.extract_includes(File.read(file))
        included_modules.each do |mod_name|
          mod_types = @rbs_type_lookup.lookup_rbs_collection_module_types(mod_name)
          mod_types.each { |name, type| types[name] ||= type }
        end
      end

      # 6. Fallback: buscar em arquivos RBS (ex: rbs_rails para AR models)
      rbs_types, rbs_superclass, rbs_includes = @rbs_type_lookup.lookup_rbs_types(class_name)
      rbs_types.each { |name, type| types[name] ||= type }

      # 7. Resolver herança: buscar tipos da superclass e módulos incluídos
      if rbs_superclass
        inherited = @rbs_type_lookup.lookup_inherited_types(rbs_superclass)
        inherited.each { |name, type| types[name] ||= type }
      end

      rbs_includes.each do |mod_name|
        mod_types = @rbs_type_lookup.lookup_inherited_types(mod_name)
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
        info = @rbs_type_lookup.parse_rbs_class_block(content, normalized)
        info.class_method_types.each { |name, type| types[name] ||= type }
      end

      @class_method_cache[class_name] = types
      types
    end

    # Escaneia source files para encontrar ClassName.new(key: val)
    # e inferir os tipos dos kwargs → attrs
    def infer_attrs_from_call_sites(class_name, types, param_to_attr)
      short_name = class_name.split("::").last

      files = @source_index ? @source_index.files_referencing(class_name) : @source_files
      files.each do |file|
        begin
          source = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
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

    # Extrai nomes de módulos incluídos via `include Foo::Bar` no source
    def extract_includes(source)
      @rbs_type_lookup.extract_includes(source)
    end

    def find_class_file(class_name)
      class_path = RbsInfer.class_name_to_path(class_name)
      @source_files.find { |f| f.end_with?("#{class_path}.rb") }
    end

    # Inferir return type a partir de literais ou Klass.new na última expressão
    def infer_literal_return_type(node, class_name = nil)
      basic = infer_node_type(node, context_class: class_name)
      return basic if basic

      case node
      when Prism::CallNode
        if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
          cn = RbsInfer::Analyzer.extract_constant_path(node.receiver)
          resolved = resolve_class_method(cn, node.name.to_s) if cn
          return resolved if resolved

          infer_block_return_type(node.block, class_name)
        elsif node.receiver.nil? && class_name
          resolved = @rbs_definition_resolver.resolve_via_rbs_builder(:instance, class_name, node.name.to_s)
          return resolved if resolved

          infer_block_return_type(node.block, class_name)
        end
      end
    end

    def infer_block_return_type(block_node, class_name)
      return nil unless block_node.is_a?(Prism::BlockNode)

      body = block_node.body
      last_stmt = case body
                  when Prism::StatementsNode then body.body.last
                  else body
                  end
      return nil unless last_stmt

      infer_literal_return_type(last_stmt, class_name)
    end
  end
  end
end

require_relative "rbs_type_lookup"
require_relative "rbs_definition_resolver"
