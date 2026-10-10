# frozen_string_literal: true

class RbsInfer::Inference::NewCallCollector < Prism::Visitor
  # Where the collector is in the file: the enclosing class and module, the
  # method being visited, and the types its locals and ivars hold there. The
  # visitor enters and leaves; `ValueTypes` and the call-site checks read.
  class Scope
    attr_reader :current_method, :current_def, :current_def_params, :caller_class_name
    attr_accessor :local_var_types, :self_condition

    def initialize(local_var_types:, caller_class_name:)
      @local_var_types = local_var_types
      @caller_class_name = caller_class_name
      @class_name_stack = []
      @module_name_stack = []
      @declaration_kinds = []
      @lexical_names = []
      @class_body_defs = []
      @class_singleton_defs = []
      @current_method = nil
      @current_def = nil
      @current_def_params = []
      @in_singleton_method = false
      @self_condition = nil
    end

    # A module declaration does not push a class name — `@class_name_stack` is
    # about the enclosing CLASS — but it does decide what `self` is inside it.
    def in_module(node)
      @declaration_kinds.push(:module)
      @module_name_stack.push(module_name_for(node))
      @lexical_names.push(lexical_name_for(node))
      yield
    ensure
      @declaration_kinds.pop
      @module_name_stack.pop
      @lexical_names.pop
    end

    def in_class(node)
      @declaration_kinds.push(:class)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
      full_name = (@class_name_stack.empty? ? segment : "#{@class_name_stack.last}::#{segment}") if segment
      @class_name_stack.push(full_name) if full_name
      @lexical_names.push(lexical_name_for(node))
      @class_body_defs.push(RbsInfer::Inference::InheritedReach.body_defs(node, :instance).to_set)
      @class_singleton_defs.push(RbsInfer::Inference::InheritedReach.body_defs(node, :singleton).to_set)
      yield
      @class_body_defs.pop
      @class_singleton_defs.pop
      @lexical_names.pop
      @class_name_stack.pop if full_name
      @declaration_kinds.pop
    end

    # The method's locals are its own: whatever the body records is dropped on
    # the way out.
    def in_def(node)
      saved = [@local_var_types.dup, @in_singleton_method, @current_method, @current_def, @current_def_params]
      # `def self.foo` carries a receiver; plain `def foo` does not.
      @in_singleton_method = !node.receiver.nil?
      @current_method = node.name.to_s
      @current_def = node
      @current_def_params = positional_param_names(node)
      yield
      @local_var_types, @in_singleton_method, @current_method, @current_def, @current_def_params = saved
    end

    # Types that hold only inside the block, restored after it.
    def with_local_types(types)
      saved = @local_var_types.dup
      types.each { |name, type| @local_var_types[name] = type }
      yield
      @local_var_types = saved
    end

    def with_self_condition(condition)
      previous = @self_condition
      @self_condition = condition
      yield
    ensure
      @self_condition = previous
    end

    def in_singleton_method? = @in_singleton_method

    def in_module? = @declaration_kinds.last == :module

    def lexical_class_name
      @class_name_stack.last || @caller_class_name
    end

    def lexical_name = @lexical_names.last

    # The module being visited, joined with whatever encloses it, or the name
    # the file stands for outside one.
    def module_name
      @module_name_stack.last || @caller_class_name
    end

    # Which side of the enclosing class's own body the current method is
    # written on (`InheritedReach.body_defs`): `:instance`, `:singleton` for a
    # `def self.` or a `def` in its `class << self`, or nil for one in a block
    # (`Class.new(Other) do`) or inside another method, which belongs to some
    # other chain.
    def own_method_side
      return nil unless @declaration_kinds.last == :class

      if @class_body_defs.last&.include?(@current_def)
        :instance
      elsif @class_singleton_defs.last&.include?(@current_def)
        :singleton
      end
    end

    private

    def lexical_name_for(node)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path) or return @lexical_names.last
      outer = @lexical_names.last

      outer ? "#{outer}::#{segment}" : segment
    end

    # A module's FQN, joined with whatever encloses it. Tracked apart from
    # `@class_name_stack`, which modules deliberately stay out of — a module
    # name is not a `self` type, and the only thing this answers is WHICH module
    # the annotators' answer was about (felixefelip/rbs_infer#161).
    def module_name_for(node)
      segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path) or return nil
      outer = @module_name_stack.last || @class_name_stack.last

      outer ? "#{outer}::#{segment}" : segment
    end

    def positional_param_names(node)
      params = node.parameters or return []

      (params.requireds + params.optionals).filter_map { |p| p.name.to_s if p.respond_to?(:name) }
    end
  end
end
