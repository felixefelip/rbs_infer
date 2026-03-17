require "steep"

module RbsInfer
  # Bridge to Steep's TypeConstruction for resolving expression types.
  #
  # Steep is a full Ruby type checker. We use it as an oracle to resolve
  # expression types (local variables, return types, method chains, ternaries,
  # conditionals, etc.) that would otherwise require manual implementation
  # for each Ruby expression pattern.
  #
  # The rbs_infer pipeline continues to handle:
  # - Caller-side parameter type inference
  # - Cross-file call analysis
  # - Attr inference via initialize
  # - RBS generation
  class SteepBridge
    # Shared RBS DefinitionBuilder, cached at the class level.
    # Both SteepBridge and RbsDefinitionResolver use the same RBS environment,
    # so we load it once and share it to avoid duplicating ~1s of loading.
    class << self
      def definition_builder
        current_dir = Dir.pwd
        if @definition_builder_loaded && @definition_builder_dir == current_dir
          return @definition_builder
        end
        @definition_builder_loaded = true
        @definition_builder_dir = current_dir
        @definition_builder = build_definition_builder
      end

      def reset!
        @definition_builder = nil
        @definition_builder_loaded = false
        @definition_builder_dir = nil
      end

      private

      def build_definition_builder
        require "rbs"

        loader = RBS::EnvironmentLoader.new

        Dir["sig/*/"].each { |d| loader.add(path: Pathname(d)) }
        Dir[".gem_rbs_collection/*/"].each do |gem_dir|
          Dir["#{gem_dir}/*/"].each { |ver_dir| loader.add(path: Pathname(ver_dir)) }
        end

        env = RBS::Environment.from_loader(loader).resolve_type_names
        RBS::DefinitionBuilder.new(env: env)
      rescue LoadError, StandardError => _e
        nil
      end
    end

    def initialize
      @subtyping = nil
      @constant_resolver = nil
      @initialized = false
    end

    # Returns { "var_name" => "Type" } for all local variable assignments
    # in all methods of the given source code.
    # Result is keyed by method name: { "method_name" => { "var" => "Type" } }
    def local_var_types_per_method(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = Hash.new { |h, k| h[k] = {} }

      typing.each_typing do |node, type|
        next unless node.type == :lvasgn
        type_str = format_type(type)
        next if type_str == "untyped" || type_str == "nil" || type_str == "bot"

        var_name = node.children[0].to_s
        method_name = find_enclosing_method(node, typing)
        next unless method_name

        result[method_name][var_name] = type_str
      end

      result
    end

    # Returns { "method_name" => "ReturnType" } for all def nodes.
    # The return type is inferred from the body of the method.
    def method_return_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = {}

      typing.each_typing do |node, _type|
        next unless node.type == :def || node.type == :defs
        method_name = node.type == :def ? node.children[0].to_s : node.children[1].to_s
        body = node.type == :def ? node.children[2] : node.children[3]
        next unless body

        body_type = typing.type_of(node: body)
        type_str = format_type(body_type)
        next if type_str == "untyped"

        result[method_name] = type_str
      end

      result
    rescue
      {}
    end

    # Returns { "var_name" => "Type" } for all instance variable writes (@var = expr).
    # The var name is without the leading @.
    def ivar_write_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = {}

      typing.each_typing do |node, type|
        next unless node.type == :ivasgn
        var_name = node.children[0].to_s.sub(/\A@/, "")
        type_str = format_type(type)
        next if type_str == "untyped" || type_str == "nil" || type_str == "bot"

        result[var_name] ||= type_str
      end

      result
    rescue
      {}
    end

    # Returns the type of a specific node within the typing result.
    # Useful for resolving argument types in call sites.
    # Returns { node_id => "Type" } for all typed expressions.
    def all_expression_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = {}

      typing.each_typing do |node, type|
        loc = node.loc&.expression
        next unless loc

        type_str = format_type(type)
        next if type_str == "untyped" || type_str == "bot"

        key = "#{loc.first_line}:#{loc.column}"
        result[key] = type_str
      end

      result
    end

    private

    def type_check(source_code)
      ensure_initialized
      return nil unless @subtyping

      source = Steep::Source.parse(source_code, path: Pathname("(rbs_infer)"), factory: @subtyping.factory)
      Steep::Services::TypeCheckService.type_check(
        source: source,
        subtyping: @subtyping,
        constant_resolver: @constant_resolver,
        cursor: nil
      )
    rescue => _e
      nil
    end

    def ensure_initialized
      return if @initialized
      @initialized = true

      definition_builder = self.class.definition_builder
      return unless definition_builder

      factory = Steep::AST::Types::Factory.new(builder: definition_builder)
      interface_builder = Steep::Interface::Builder.new(factory, implicitly_returns_nil: false)
      @subtyping = Steep::Subtyping::Check.new(builder: interface_builder)
      @constant_resolver = RBS::Resolver::ConstantResolver.new(builder: definition_builder)
    rescue => _e
      @subtyping = nil
      @constant_resolver = nil
    end

    def format_type(steep_type)
      str = steep_type.to_s

      # Remove leading :: from all type names
      str = str.gsub(/(^|[\[\(, |])::/) { $1 }

      # Normalize (T | nil) to T?
      if str =~ /\A\((.+) \| nil\)\z/
        inner = $1.strip
        return "#{inner}?" unless inner.include?("|")
      end
      if str =~ /\A\(nil \| (.+)\)\z/
        inner = $1.strip
        return "#{inner}?" unless inner.include?("|")
      end

      str
    end

    def find_enclosing_method(node, typing)
      # Walk up from the node to find the enclosing def
      # Since Parser AST nodes don't have parent pointers, we search
      # through the typing's source node tree
      source_node = typing.source.node
      find_method_for_node(source_node, node)
    end

    def find_method_for_node(root, target)
      current_method = nil
      search_for_method(root, target, current_method)
    end

    def search_for_method(node, target, current_method)
      return nil unless node.is_a?(Parser::AST::Node)

      if node.type == :def
        current_method = node.children[0].to_s
      elsif node.type == :defs
        current_method = node.children[1].to_s
      end

      return current_method if node.equal?(target)

      node.children.each do |child|
        result = search_for_method(child, target, current_method)
        return result if result
      end

      nil
    end
  end
end
