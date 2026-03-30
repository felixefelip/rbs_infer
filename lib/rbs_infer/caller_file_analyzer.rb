module RbsInfer
  class CallerFileAnalyzer
    include RbsAnnotationParser

    attr_reader :method_call_usages

    def initialize(target_class:, method_type_resolver:, init_positional_params: [], target_methods: {}, steep_bridge: nil)
      @target_class = target_class
      @method_type_resolver = method_type_resolver
      @init_positional_params = init_positional_params
      @target_methods = target_methods
      @steep_bridge = steep_bridge
      @method_call_usages = Hash.new { |h, k| h[k] = [] }
    end

    def analyze(file)
      source = File.read(file)
      result = Prism.parse(source)
      comments = result.comments
      method_return_types = extract_method_return_types(source, comments, result.value)

      # Incluir tipos de attr_reader/attr_accessor como retorno de métodos
      # (em Ruby, attr_reader :foo gera um método foo)
      extract_attr_return_types(source, comments, result.value).each do |name, type|
        method_return_types[name] ||= type
      end

      # Resolver tipos do caller class via MethodTypeResolver
      # (infere attrs sem anotação via keyword defaults e call-sites)
      caller_visitor = ClassNameExtractor.new
      result.value.accept(caller_visitor)
      if caller_visitor.class_name
        caller_types = @method_type_resolver.resolve_all(caller_visitor.class_name)
        caller_types.each do |name, type|
          method_return_types[name] ||= type
        end
      end

      local_var_types = {}

      # Use Steep to resolve local var types (including block params)
      if @steep_bridge
        steep_vars = @steep_bridge.local_var_types_per_method(source)
        steep_vars.each_value { |vars| local_var_types.merge!(vars) { |_k, old, _new| old } }
      end

      # Enable bare call matching when the file includes the target module/concern.
      # e.g. PostsController includes FilterConfiguration → configure_filter("posts")
      # is a bare call that would otherwise be invisible to cross-class analysis.
      short_name = @target_class.split("::").last
      match_bare = source.match?(/\binclude\b.*\b#{Regexp.escape(short_name)}\b/)

      visitor = NewCallCollector.new(
        target_class: @target_class,
        method_return_types: method_return_types,
        local_var_types: local_var_types,
        method_type_resolver: @method_type_resolver,
        caller_class_name: caller_visitor.class_name,
        init_positional_params: @init_positional_params,
        target_methods: @target_methods,
        match_bare_calls: match_bare
      )
      result.value.accept(visitor)

      visitor.method_call_usages.each do |method_name, usages|
        @method_call_usages[method_name].concat(usages)
      end

      visitor.usages
    end

    # Analyze pre-converted source code (e.g. ERB → Ruby) with known local/ivar types.
    # Matches bare calls against target_methods (for included module methods).
    def analyze_source(source, local_var_types: {})
      result = Prism.parse(source)

      # Resolve block param types from iterator calls on known-type collections
      resolve_block_param_types(result.value, local_var_types)

      visitor = NewCallCollector.new(
        target_class: @target_class,
        method_return_types: {},
        local_var_types: local_var_types,
        method_type_resolver: @method_type_resolver,
        init_positional_params: @init_positional_params,
        target_methods: @target_methods,
        match_bare_calls: true
      )
      result.value.accept(visitor)

      visitor.method_call_usages.each do |method_name, usages|
        @method_call_usages[method_name].concat(usages)
      end

      visitor.usages
    end

    private

    ITERATOR_METHODS = RbsInfer::ITERATOR_METHODS

    # Resolve block param types from iterator calls on known-type ivars/locals.
    # e.g. @posts.each do |post| → post: Post (when @posts: Post::ActiveRecord_Relation)
    def resolve_block_param_types(tree, local_var_types)
      RbsInfer::Analyzer.find_all_nodes(tree) do |node|
        node.is_a?(Prism::CallNode) && ITERATOR_METHODS.include?(node.name) && node.block
      end.each do |call|
        block = call.block
        next unless block.is_a?(Prism::BlockNode)

        params = block.parameters&.parameters
        next unless params

        param_names = []
        params.requireds.each { |p| param_names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
        next if param_names.empty?

        collection_type = resolve_receiver_collection_type(call.receiver, local_var_types)
        next unless collection_type

        element_type = extract_element_type(collection_type)
        next unless element_type

        # First block param gets the element type
        local_var_types[param_names.first] ||= element_type
      end
    end

    def resolve_receiver_collection_type(receiver, local_var_types)
      case receiver
      when Prism::InstanceVariableReadNode
        local_var_types[receiver.name.to_s.sub(/\A@/, "")]
      when Prism::LocalVariableReadNode
        local_var_types[receiver.name.to_s]
      when Prism::CallNode
        # method chain: e.g. @post.comments.recent → resolve via method_type_resolver
        nil
      end
    end

    # Extract element type from collection types via RBS definitions.
    # Looks up the `each` method's block parameter type.
    def extract_element_type(collection_type)
      @rbs_definition_resolver ||= RbsDefinitionResolver.new
      @rbs_definition_resolver.resolve_each_element_type(collection_type)
    end

    def extract_attr_return_types(source, comments, tree)
      types = {}
      lines = source.lines
      collector = ClassMemberCollector.new(comments: comments, lines: lines)
      tree.accept(collector)
      collector.members.each do |member|
        next unless [:attr_accessor, :attr_reader].include?(member.kind)
        if member.signature =~ /\w+:\s*(.+)/
          type = $1.strip
          types[member.name] = type unless type == "untyped"
        end
      end
      types
    end

    def extract_method_return_types(source, comments, tree)
      types = {}
      lines = source.lines

      def_visitor = DefCollector.new
      tree.accept(def_visitor)

      def_visitor.defs.each do |defn|
        def_line = defn.location.start_line
        method_name = defn.name.to_s

        return_type = find_rbs_return_type(comments, lines, def_line)
        return_type ||= infer_return_type_from_body(defn)

        types[method_name] = return_type if return_type
      end

      types
    end

    def find_rbs_return_type(comments, lines, def_line)
      comments.each do |comment|
        comment_line = comment.location.start_line
        next unless comment_line.between?(def_line - 3, def_line - 1)
        next unless lines_between_are_blank_or_comments(lines, comment_line, def_line)

        text = comment.location.slice

        # @rbs () -> ReturnType
        if text =~ /@rbs\s*\(.*?\)\s*->\s*(.+)/
          return $1.strip
        end

        # #: () -> ReturnType  ou  #: -> ReturnType
        if text =~ /#:\s*(?:\(.*?\)\s*)?->\s*(.+)/
          return $1.strip
        end
      end
      nil
    end

    def infer_return_type_from_body(defn)
      body = defn.body
      return nil unless body

      last_stmt = case body
                  when Prism::StatementsNode then body.body.last
                  else body
                  end

      return nil unless last_stmt

      if last_stmt.is_a?(Prism::CallNode) && last_stmt.name == :new && last_stmt.receiver
        class_name = RbsInfer::Analyzer.extract_constant_path(last_stmt.receiver)
        return class_name if class_name
      end

      nil
    end
  end
end
