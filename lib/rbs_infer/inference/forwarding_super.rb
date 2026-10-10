# frozen_string_literal: true

module RbsInfer::Inference
  # A bare `super` written out as the call it is (felixefelip/rbs_infer#412):
  #
  #   def initialize(name, *rest, flag:)   # super
  #                                         # => super(name, *rest, flag: flag)
  #
  # Ruby passes each parameter's CURRENT value, so the explicit form is the
  # same call, block included. Written out, every argument is a local read the
  # checker types where it stands, narrowing and reassignment included, and
  # the call is read like any other `super(...)`.
  #
  # Left bare where the explicit form cannot be written or would read
  # something else: an anonymous or destructured parameter, `...`, and a
  # `super` inside a block whose parameters shadow one of the method's (the
  # bare form still passes the method's value, a written read would take the
  # block's).
  module ForwardingSuper
    module_function

    def desugar(source)
      return source unless source.include?("super")

      result = Prism.parse(source)
      return source unless result.success?

      insertions = []
      collect(result.value, nil, Set.new, insertions)
      return source if insertions.empty?

      bytes = source.b
      insertions.sort_by(&:first).reverse_each { |offset, text| bytes.insert(offset, text) }
      bytes.force_encoding(source.encoding)
    end

    def collect(node, def_node, shadowed, insertions)
      case node
      when Prism::DefNode
        def_node = node
        shadowed = Set.new
      when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        def_node = nil
      when Prism::BlockNode, Prism::LambdaNode
        shadowed |= block_locals(node)
      when Prism::ForwardingSuperNode
        if def_node && (arguments = arguments_for(def_node)) && (arguments.map { |a| a[/\w+/] } & shadowed.to_a).empty?
          insertions << [node.location.start_offset + "super".bytesize, "(#{arguments.join(", ")})"]
        end
      end

      node.compact_child_nodes.each { |child| collect(child, def_node, shadowed, insertions) }
    end

    # The method's parameters as `super` passes them, or nil when one of them
    # has no name to read.
    def arguments_for(def_node) # rubocop:todo Metrics/MethodLength
      params = def_node.parameters
      return [] unless params
      return nil if params.keyword_rest.is_a?(Prism::ForwardingParameterNode)

      arguments = []
      (params.requireds + params.optionals).each do |param|
        name = param.respond_to?(:name) && param.name or return nil
        arguments << name.to_s
      end
      if (rest = params.rest)
        return nil unless rest.respond_to?(:name) && rest.name

        arguments << "*#{rest.name}"
      end
      params.posts.each do |param|
        name = param.respond_to?(:name) && param.name or return nil
        arguments << name.to_s
      end
      params.keywords.each { |keyword| arguments << "#{keyword.name}: #{keyword.name}" }
      case (keyword_rest = params.keyword_rest)
      when Prism::KeywordRestParameterNode
        return nil unless keyword_rest.name

        arguments << "**#{keyword_rest.name}"
      when nil, Prism::NoKeywordsParameterNode
        nil
      else
        return nil
      end
      arguments
    end

    def block_locals(node)
      params = node.parameters or return Set.new
      names = Set.new
      RbsInfer::Analyzer.find_all_nodes(params) { |n| n.respond_to?(:name) && n.name.is_a?(Symbol) }
                        .each { |n| names << n.name.to_s }
      names
    end
  end
end
