module RbsInfer
  # Resolve return types de métodos e tipos de instance variables
  # a partir de análise estática do corpo dos métodos.
  #
  # Extraído de Analyzer para manter responsabilidades separadas:
  # - improve_method_return_types: resolve return types de métodos via chain resolution
  # - infer_ivar_types: infere tipos de instance variables (@post, @posts, etc.)

  class ReturnTypeResolver
    include KnownReturnTypesBuilder

    def initialize(target_file:, target_class:, method_type_resolver:, instance_types: [], steep_bridge: nil)
      @target_file = target_file
      @target_class = target_class
      @method_type_resolver = method_type_resolver
      @instance_types = instance_types
      @steep_bridge = steep_bridge
    end

    def improve_method_return_types(members, attr_types, parsed_target: nil)
      return unless parsed_target

      # Métodos com return type untyped
      untyped_methods = members.select { |m| m.kind == :method && m.signature =~ /->\ s*untyped$/ }
      return if untyped_methods.empty?

      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class, instance_types: @instance_types)

      # Aplicar tipos já resolvidos pelo resolver (ex: chamadas a métodos herdados)
      untyped_methods.each do |m|
        next if m.name == "initialize"
        resolved = known_return_types[m.name]
        if resolved && resolved != "untyped"
          m.signature = m.signature.sub(/-> untyped$/, "-> #{resolved}")
        end
      end

      # Use Steep for any remaining untyped methods and to correct wrong block generic types
      if @steep_bridge && parsed_target.source
        still_untyped = members.select { |m| m.kind == :method && m.name != "initialize" && m.signature =~ /->\s*untyped$/ }
        steep_returns = @steep_bridge.method_return_types(parsed_target.source)

        unless steep_returns.empty?
          # Build def map for nil-return detection
          collector = DefCollector.new
          parsed_target.tree.accept(collector)
          def_map = {}
          collector.defs.each { |d| def_map[d.name.to_s] = d if d.is_a?(Prism::DefNode) }

          self_types = Set.new([@target_class] + @instance_types)

          still_untyped.each do |m|
            steep_type = steep_returns[m.name]
            if steep_type && steep_type != "untyped" && steep_type != "nil" && steep_type != "bot"
              # Instance methods returning the same class (or host class for concerns) → self
              steep_type = "self" if self_types.include?(steep_type)

              # Check for early return nil in body
              defn = def_map[m.name]
              if defn && has_nil_return?(defn) && !steep_type.end_with?("?")
                steep_type = "#{steep_type}?"
              end

              m.signature = m.signature.sub(/-> untyped$/, "-> #{steep_type}")
            end
          end

          # Correct already-typed methods where Steep detected BlockBodyTypeMismatch
          # (existing RBS had wrong type from previous generation)
          members.each do |m|
            next if m.kind != :method || m.name == "initialize"
            next if m.signature =~ /->\s*untyped$/
            steep_type = steep_returns[m.name]
            next unless steep_type && steep_type != "untyped" && steep_type != "nil" && steep_type != "bot"
            current_type = m.signature[/->\s*(.+)$/, 1]&.strip
            next if current_type == steep_type
            # Only override Array types (block generic correction)
            next unless current_type&.start_with?("Array[") && steep_type.start_with?("Array[")
            m.signature = m.signature.sub(/-> #{Regexp.escape(current_type)}$/, "-> #{steep_type}")
          end

          # Refine record types containing untyped values using Steep's body type inference
          members.each do |m|
            next if m.kind != :method || m.name == "initialize"
            current_type = m.signature[/->\s*(.+)$/, 1]&.strip
            next unless current_type&.start_with?("{") && current_type.include?("untyped")

            steep_type = steep_returns[m.name]
            next unless steep_type && steep_type != "untyped" && steep_type != "nil" && steep_type != "bot"
            next unless steep_type.start_with?("{")
            next if current_type == steep_type

            steep_type = "self" if self_types.include?(steep_type)

            defn = def_map[m.name]
            if defn && has_nil_return?(defn) && !steep_type.end_with?("?")
              steep_type = "#{steep_type}?"
            end

            m.signature = m.signature.sub(/-> #{Regexp.escape(current_type)}$/, "-> #{steep_type}")
          end
        end
      end
    end

    def infer_ivar_types(members, attr_types, parsed_target: nil)
      return {} unless parsed_target

      # Nomes de attrs já declarados (attr_accessor, attr_reader) → pular
      attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                          .map(&:name).to_set

      ivar_types = {}

      # Use Steep for ivar type resolution
      if @steep_bridge && parsed_target.source
        steep_ivars = @steep_bridge.ivar_write_types(parsed_target.source)
        steep_ivars.each do |name, type|
          next if attr_names.include?(name)
          ivar_types[name] = type
        end
      end

      # Fallback: basic ivar type inference for cases Steep doesn't cover
      known_return_types = build_known_return_types(members, attr_types, method_type_resolver: method_type_resolver, target_class: @target_class, instance_types: @instance_types)

      collector = DefCollector.new
      parsed_target.tree.accept(collector)

      collector.defs.each do |defn|
        collect_ivar_writes(defn, known_return_types, ivar_types, attr_names)
      end

      ivar_types
    end

    private

    attr_reader :method_type_resolver

    # Verifica se o corpo do método contém `return nil` ou `return` (implícito nil)
    def has_nil_return?(defn)
      RbsInfer::Analyzer.find_all_nodes(defn) do |node|
        next false unless node.is_a?(Prism::ReturnNode)
        node.arguments.nil? ||
          node.arguments.arguments.any? { |arg| arg.is_a?(Prism::NilNode) }
      end.any?
    end

    def collect_ivar_writes(node, known_return_types, ivar_types, attr_names)
      queue = [node]
      while (current = queue.shift)
        if current.is_a?(Prism::InstanceVariableWriteNode)
          name = current.name.to_s.sub(/\A@/, "")
          next if attr_names.include?(name)
          next if ivar_types[name] && ivar_types[name] != "untyped"

          inferred = basic_value_type(current.value, known_return_types)
          if inferred && inferred != "untyped"
            ivar_types[name] = inferred
            known_return_types[name] = inferred
          end
        end
        queue.concat(current.compact_child_nodes)
      end
    end

    # Basic type inference for ivar assignment values — handles literals,
    # Klass.new, and simple same-class method lookups.
    # Complex chain resolution is delegated to Steep.
    def basic_value_type(node, known_return_types)
      case node
      when Prism::StringNode, Prism::InterpolatedStringNode then "String"
      when Prism::IntegerNode then "Integer"
      when Prism::FloatNode then "Float"
      when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "Symbol"
      when Prism::TrueNode, Prism::FalseNode then "bool"
      when Prism::ArrayNode then "Array[untyped]"
      when Prism::HashNode then NodeTypeInferrer.infer_hash_type(node, known_types: known_return_types, context_class: @target_class)
      when Prism::SelfNode then @target_class
      when Prism::CallNode
        if node.name == :new && node.receiver
          Analyzer.extract_constant_path(node.receiver)
        elsif node.receiver.nil?
          known_return_types[node.name.to_s]
        end
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        Analyzer.extract_constant_path(node)
      end
    end
  end
end
