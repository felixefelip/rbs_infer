module RbsInfer::Signatures
  # ─── Resolvedor de tipos inter-procedural ──────────────────────────
  # Dado um class_name e method_name, encontra o arquivo fonte da classe,
  # parseia e retorna o tipo de retorno do método.
  # Também infere tipos de attrs via keyword defaults e call-sites.

  class MethodTypeResolver
    include RbsInfer::AST::NodeTypeInferrer

    attr_reader :constant_resolver

    # constant_resolver: required (felixefelip/rbs_infer#56). Env-aware resolver
    # for value-position constants in the classes this resolver analyzes (e.g.
    # another class's init keyword default → its VALUE type, not its bare name).
    # Required, not defaulted: a caller that forgets it silently degrades those
    # types to untyped. Callers without a project SteepBridge can still pass an
    # env-only ConstantArgTypeResolver (the RBS env is process-global).
    # mixin_index: required (felixefelip/rbs_infer#175). It is what says who
    # includes a module, and therefore what `self` is inside one — so a call site
    # in a concern (`Detector.new(self)`) has a type to pass. A caller that
    # forgets it does not fail: `self` resolves to `untyped` on this path, the
    # parameter it feeds goes untyped with it, and the class's contracts stop
    # being inferrable. Passed in rather than built here, because building one is
    # a full sweep of the project's files and the Analyzer already has it.
    # invoker_self_types: required for the same reason and on the same path — it
    # is what narrows that module `self` from every host to the ones that call
    # the method being read (felixefelip/rbs_infer#222).
    def initialize(source_files, constant_resolver:, mixin_index:, invoker_self_types:, source_index: nil, parse_cache: nil, file_index: nil, caller_file_cache: nil)
      @source_files = source_files
      @source_index = source_index
      @constant_resolver = constant_resolver
      @mixin_index = mixin_index
      @invoker_self_types = invoker_self_types
      @parse_cache = parse_cache || RbsInfer::Project::ParseCache.new
      @file_index = file_index || RbsInfer::Project::FileIndex.new(source_files)
      @caller_file_cache = caller_file_cache || RbsInfer::Project::CallerFileCache.new(@parse_cache)
      @cache = {}
      @nil_branch_cache = {}
      @building = Set.new # guard contra recursão infinita
      @rbs_type_lookup = RbsTypeLookup.new
      @rbs_definition_resolver = RbsDefinitionResolver.new
    end

    # The RBS type-parameter list of an existing class ("[unchecked out
    # Elem]"), or "" — used when reopening a generic class so the emitted
    # declaration matches (felixefelip/rbs_infer#38).
    def type_param_string(class_name)
      @rbs_definition_resolver.type_param_string(class_name)
    end

    # A constant as WRITTEN in source, resolved to the class it actually names.
    # Ruby searches the lexical scope from the inside out, so `Archiver` written
    # inside `Post` is `Post::Archiver` when that exists (felixefelip/rbs_infer#129).
    #
    # `enclosing` is required, not defaulted: a call site that forgets to pass its
    # lexical context does not fail — it resolves the bare name against the top
    # level, finds nothing, and yields `untyped`. That silent degradation is
    # exactly how this bug survived three pointwise fixes
    # (docs/engineering/required-threaded-deps.md).
    #
    # Returns `name` unchanged when no candidate is known, so a constant this
    # project cannot see (stdlib, a gem, a dynamically defined class) keeps
    # flowing to the resolvers that can.
    def qualify_constant(name, enclosing:)
      return name unless name

      RbsInfer::AST::LexicalConstantResolver.resolve(name: name, enclosing: enclosing) do |candidate|
        known_class?(candidate)
      end || name
    end

    def resolve(class_name, method_name, arg_types:, block_body_type: nil)
      return nil unless class_name && class_name != "untyped"

      # Nilable receiver (`User?`): the call has TWO branches and both are real
      # Ruby, so resolve the base type AND `NilClass`.
      #
      # When NilClass does not define the method, the nil branch would be a
      # NoMethodError — the app's steep check flags it, and the optimistic
      # base-only answer is the useful one, just as a human reading `user.name`
      # knows the method belongs to User (felixefelip/rbs_infer#19).
      #
      # When it DOES define it (`present?`, `blank?`, `nil?`, `to_s`), the nil
      # branch is ordinary code, and it usually answers the OPPOSITE constant of
      # the base: `ActiveRecord::Core#present?: () -> true` (Rails short-circuits
      # `Object#blank?`'s `respond_to?(:empty?)` with a literal) against
      # `NilClass#present?: () -> false`. Dropping it emitted `-> true` for
      # `goldness.present?` on a nilable `has_one` — a body that plainly returns
      # false when the association is nil, which Steep then rejects with
      # "Cannot allow method body have type `(true | false)` … declared as `true`".
      if class_name.end_with?("?")
        return resolve_nilable(class_name.delete_suffix("?"), method_name, block_body_type: block_body_type,
                               arg_types: arg_types)
      end

      # Intersection types (e.g. `(OrderImport & OrderImport::Validated)` from
      # finders that now return `Model & Model::Validated`) need to be split
      # before lookup — `RBS::TypeName` only accepts a single nominal name.
      # Resolve right-to-left to match `Steep::Interface::Builder.intersection_shape`,
      # which gives precedence to later components in the intersection.
      if (components = parse_intersection(class_name))
        components.reverse_each do |component|
          result = resolve(component, method_name, block_body_type: block_body_type, arg_types: arg_types)
          return result if result && result != "untyped"
        end
        return nil
      end

      # Union types (e.g. `User | (User & User::Validated)` from ivars
      # with heterogeneous call-sites — the union form is deliberately
      # not simplified, see IvarTypeSet). The method only resolves if ALL
      # components agree on the return type; divergence → nil (ambiguous,
      # better untyped than a guess) — felixefelip/rbs_infer#19.
      if (components = parse_union(class_name))
        results = components.map { |c| resolve(c, method_name, block_body_type: block_body_type, arg_types: arg_types) }
        return nil if results.any?(&:nil?)
        return results.first if results.uniq.length == 1
        return nil
      end

      # Tentar via RBS DefinitionBuilder primeiro (resolve genéricos corretamente)
      rbs_result = @rbs_definition_resolver.resolve_via_rbs_builder(:instance, class_name, method_name,
                                                                    block_body_type: block_body_type,
                                                                    arg_types: arg_types)
      return rbs_result if rbs_result && rbs_result != "untyped"

      # Fallback: source + regex-based resolution
      class_types = resolve_all(class_name)
      class_types[method_name] || class_types[method_name.delete_suffix("!").delete_suffix("?")]
    end

    # The two branches of a call on a nilable receiver, unioned. See `resolve`
    # for why the nil branch is not optional.
    private def resolve_nilable(base, method_name, arg_types:, block_body_type:)
      base_result = resolve(base, method_name, block_body_type: block_body_type, arg_types: arg_types)
      return base_result if base_result.nil? || base_result == "untyped"

      nil_result = nil_branch(method_name, block_body_type, arg_types)
      return base_result if nil_result.nil? || nil_result == "untyped"
      return base_result if base_result == nil_result

      # `self` is receiver-relative, and the two branches have DIFFERENT
      # receivers — `NilClass#tap: () -> self` is nil, the base's is the base.
      # The caller substitutes a returned `self` against one receiver type
      # (`TypeMerger#infer_call_return_type`), so a union spanning both is not
      # expressible in what this method returns; keep the base's answer.
      return base_result if self_relative?(base_result) || self_relative?(nil_result)

      RbsInfer::Inference::TypeMerger.union_types([base_result, nil_result])
    end

    # `NilClass`'s own surface, memoized: every nilable receiver in the project
    # asks the same question, and the answer never varies by call-site.
    #
    # The nil branch is the SAME call, so it gets the same arguments — and they
    # belong in the key: `NilClass#+` answered for one argument list must not be
    # served to another, which is the bug the memo would otherwise introduce the
    # moment overload selection started depending on them.
    private def nil_branch(method_name, block_body_type, arg_types)
      key = [method_name, block_body_type, arg_types]
      return @nil_branch_cache[key] if @nil_branch_cache.key?(key)

      @nil_branch_cache[key] = resolve("NilClass", method_name, block_body_type: block_body_type,
                                                               arg_types: arg_types)
    end

    private def self_relative?(type)
      contains_self?(RBS::Parser.parse_type(type))
    rescue RBS::ParsingError, RBS::BaseError
      true
    end

    private def contains_self?(rbs_type)
      rbs_type.is_a?(RBS::Types::Bases::Self) || rbs_type.each_type.any? { |t| contains_self?(t) }
    end

    # Parses an intersection-type string via `RBS::Parser.parse_type` and
    # returns the component names. Returns nil for non-intersection (or
    # unparseable) strings so the caller can take the legacy fast path.
    # Using RBS's own parser handles nested unions, generics, and parens
    # without hand-rolling a splitter.
    private def parse_intersection(class_name)
      parsed = RBS::Parser.parse_type(class_name)
      return nil unless parsed.is_a?(RBS::Types::Intersection)
      parsed.types.map(&:to_s)
    rescue RBS::ParsingError
      nil
    end

    private def parse_union(class_name)
      parsed = RBS::Parser.parse_type(class_name)
      return nil unless parsed.is_a?(RBS::Types::Union)
      parsed.types.map(&:to_s)
    rescue RBS::ParsingError
      nil
    end

    # Resolve um método de classe (def self.xxx) via RBS
    def resolve_class_method(class_name, method_name, block_body_type: nil)
      return nil unless class_name && class_name != "untyped"

      # Tentar via RBS DefinitionBuilder primeiro (resolve genéricos corretamente)
      # The singleton path does not carry the call's arguments yet: every caller
      # below reaches it with a method NAME only. Saying so keeps the gap visible
      # rather than letting it read as an oversight.
      resolved = @rbs_definition_resolver.resolve_via_rbs_builder(:singleton, class_name, method_name,
                                                                 arg_types: nil, block_body_type: block_body_type)
      return resolved if resolved

      # Fallback: regex-based lookup
      class_methods = lookup_class_methods(class_name)
      class_methods[method_name]
    end

    def resolve_all(class_name)
      return {} unless class_name && class_name != "untyped"
      @cache[class_name] ||= build_class_types(class_name)
    end

    # What a method ACCEPTS, as its class declares it — the counterpart of
    # `resolve`/`resolve_class_method`, which answer what it RETURNS. One
    # rendered parameter list per overload, `[]` when no declaration answers.
    # See `RbsDefinitionResolver#method_parameters`.
    def resolve_method_parameters(kind, class_name, method_name)
      return [] unless class_name && class_name != "untyped"

      @rbs_definition_resolver.method_parameters(kind, class_name, method_name)
    end


    # All class (singleton) method return types for a class, keyed by name —
    # the singleton counterpart of `resolve_all`. Lets callers resolve a
    # class method's body against other class methods without pulling in the
    # instance-method table (felixefelip/rbs_infer#33).
    def resolve_all_class_methods(class_name)
      return {} unless class_name && class_name != "untyped"
      lookup_class_methods(class_name)
    end

    # Declared instance-variable types of a class, keyed WITH the `@`
    # (`{"@post" => "Post"}`), read from its RBS (felixefelip/rbs_infer#111).
    #
    # A previous pass already wrote `@post: Post` for the class; this lets a call
    # site that passes `@post` as an argument READ that instead of re-deriving it
    # from the assignment's shape — which only ever recognized `@x = Foo.new`.
    def resolve_ivar_types(class_name)
      return {} unless class_name && class_name != "untyped"

      @ivar_types_cache ||= {}
      @ivar_types_cache[class_name] ||= @rbs_type_lookup.lookup_ivar_types(class_name)
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

    # What `self` is in each module the scanned file declares, so a call site
    # inside a concern passes the host's type rather than nothing. Both walks
    # below scan caller files exactly as the Analyzer's own walk does, and this
    # is the piece they were missing (felixefelip/rbs_infer#175).
    def module_self_types_for(file, entry, defined_names)
      RbsInfer::Project::SelfTypeAnnotators.instance_types(
        path: file, module_names: defined_names, source: entry.source, mixin_index: @mixin_index
      )
    end

    def build_init_param_types(class_name)
      @building_init_params ||= Set.new
      return {} if @building_init_params.include?(class_name)
      @building_init_params.add(class_name)

      types = {}
      short_name = class_name.split("::").last
      all_usages = []

      files = @source_index ? @source_index.files_referencing(class_name) : @source_files
      files.each do |file|
        entry = @parse_cache.get(file)
        next unless entry
        next unless entry.source.include?(short_name)

        analysis = @caller_file_cache.get(file)
        next unless analysis

        # Montar method_return_types do caller a partir dos membros já coletados
        mrt = {}
        analysis.members.each do |m|
          case m.kind
          when :method
            if m.signature =~ /.*->\s*(.+)$/
              mrt[m.name] = $1.strip
            end
          when :attr_accessor, :attr_reader
            if m.signature =~ /\w+:\s*(.+)/
              type = $1.strip
              mrt[m.name] ||= type unless type == "untyped"
            end
          end
        end

        caller_class_name = analysis.class_name
        if caller_class_name
          caller_types = resolve_all(caller_class_name)
          caller_types.each { |name, type| mrt[name] ||= type }
        end

        local_var_types = {}
        defined_names = RbsInfer::Inference::NewCallCollector.collect_defined_class_names(entry.result.value)
        visitor = RbsInfer::Inference::NewCallCollector.new(
          target_class: class_name,
          method_return_types: mrt,
          local_var_types: local_var_types,
          method_type_resolver: self,
          caller_class_name: caller_class_name,
          # Env-aware resolver so constant call-site args resolve to their value
          # type via the loaded RBS env, not a bare name (#46, #56).
          constant_arg_resolver: @constant_resolver,
          defined_class_names: defined_names,
          module_self_types: module_self_types_for(file, entry, defined_names),
          invoker_self_types: @invoker_self_types
        )
        entry.result.value.accept(visitor)
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
        entry = @parse_cache.get(file)

        if entry
          result = entry.result
          comments = result.comments
          lines = entry.source.lines

          # 1. Tipos anotados via ClassMemberCollector
          collector = RbsInfer::Inference::ClassMemberCollector.new(comments: comments, lines: lines)
          result.value.accept(collector)

          attr_names = Set.new
          collector.members.each do |member|
            case member.kind
            when :method
              if member.signature =~ /.*->\s*(.+)$/
                type = $1.strip
                # `untyped` is not an answer, it is the absence of one — recording
                # it OCCUPIES the slot, and every later source here fills with
                # `||=`, so the RBS lookup at step 6 never got to speak. That is
                # how `Example21#ticket` read `untyped` in this map while
                # `#resolve` — which asks RBS first — answered
                # `Example21::Ticket?` for the same method
                # (felixefelip/rbs_infer#168). The attr branch below has always
                # skipped it; the method branch had not.
                types[member.name] = type unless type == "untyped"
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
          def_collector = RbsInfer::AST::DefCollector.new
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
          init_visitor = RbsInfer::Inference::InitializeBodyAnalyzer.new(constant_resolver: @constant_resolver)
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

          # 5. Tipos de módulos incluídos (via RBS collection)
          included_modules = @rbs_type_lookup.extract_includes(entry.result.value)
          included_modules.each do |mod_name|
            mod_types = @rbs_type_lookup.lookup_rbs_collection_module_types(mod_name)
            mod_types.each { |name, type| types[name] ||= type }
          end
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

      RbsTypeLookup.glob("sig/**/*.rbs").each do |rbs_file|
        next unless @rbs_type_lookup.cached_content_for(rbs_file).include?(normalized.split("::").last)
        info = @rbs_type_lookup.class_info_from_file(rbs_file, normalized)
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
        entry = @parse_cache.get(file)
        next unless entry
        next unless entry.source.include?(short_name)

        analysis = @caller_file_cache.get(file)
        next unless analysis

        # Extrair tipos de métodos anotados via #: nos defs já coletados
        comments = entry.result.comments
        method_return_types = {}
        analysis.defs.each do |defn|
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

        # Incluir attr types anotados a partir dos membros já coletados
        analysis.members.each do |m|
          next unless [:attr_accessor, :attr_reader].include?(m.kind)
          if m.signature =~ /\w+:\s*(.+)/
            type = $1.strip
            method_return_types[m.name] ||= type unless type == "untyped"
          end
        end

        caller_class_name = analysis.class_name
        if caller_class_name
          caller_types = resolve_all(caller_class_name)
          caller_types.each { |name, type| method_return_types[name] ||= type }
        end

        local_var_types = {}
        defined_names = RbsInfer::Inference::NewCallCollector.collect_defined_class_names(entry.result.value)
        visitor = RbsInfer::Inference::NewCallCollector.new(
          target_class: class_name,
          method_return_types: method_return_types,
          local_var_types: local_var_types,
          method_type_resolver: self,
          caller_class_name: caller_class_name,
          # Env-aware resolver so constant call-site args resolve to their value
          # type via the loaded RBS env, not a bare name (#46, #56).
          constant_arg_resolver: @constant_resolver,
          defined_class_names: defined_names,
          module_self_types: module_self_types_for(file, entry, defined_names),
          invoker_self_types: @invoker_self_types
        )
        entry.result.value.accept(visitor)

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
      @file_index.find(class_path)
    end

    # Existence oracle for `qualify_constant`: a class this project can see, either
    # as a source file or as an RBS declaration (rbs_rails output, a gem shim, a
    # previous pass's `sig/`). Memoized — the walk asks about the same candidates
    # repeatedly across a file's methods.
    def known_class?(candidate)
      @known_class_cache ||= {}
      return @known_class_cache[candidate] if @known_class_cache.key?(candidate)

      @known_class_cache[candidate] =
        !find_class_file(candidate).nil? || RbsTypeLookup.files_declaring(candidate).any?
    end

    # Inferir return type a partir de literais ou Klass.new na última expressão
    def infer_literal_return_type(node, class_name = nil)
      # A bare constant as the return expression is a VALUE (value constant →
      # its value type) or a class object (→ `singleton(K)`), never the bare
      # name `infer_node_type` yields — invalid RBS for the former, wrong for
      # the latter. Leave it unresolved so the method stays `untyped` and the
      # Steep-backed return pass types it (felixefelip/rbs_infer#46).
      return nil if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      basic = infer_node_type(node, context_class: class_name)
      return basic if basic

      case node
      when Prism::CallNode
        if node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
          cn = RbsInfer::Analyzer.extract_constant_path(node.receiver)
          resolved = resolve_class_method(cn, node.name.to_s) if cn
          return resolved if resolved && resolved != "untyped"

          infer_block_return_type(node.block, class_name)
        elsif node.receiver.nil? && class_name
          resolved = @rbs_definition_resolver.resolve_via_rbs_builder(:instance, class_name, node.name.to_s,
                                                                     arg_types: nil)
          return resolved if resolved && resolved != "untyped"

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

require_relative "rbs_type_lookup"
require_relative "rbs_definition_resolver"
