module RbsInfer
  class ClassNameExtractor < Prism::Visitor
    def initialize(file_path:)
      @file_path = file_path
      @namespace = []
      @candidates = []
    end

    def visit_module_node(node)
      record(node, is_module: true) { super }
    end

    def visit_class_node(node)
      record(node, is_module: false) { super }
    end

    def class_name
      pick_target&.fetch(:name)
    end

    def is_module
      pick_target&.fetch(:is_module) || false
    end

    private

    def record(node, is_module:)
      name = extract_const_name(node.constant_path)
      qualified = (@namespace + [name]).join("::")
      @candidates << { name: qualified, is_module: is_module }
      @namespace.push(name)
      yield
      @namespace.pop
    end

    def pick_target
      @target ||= match_by_file_path || fallback_pick
    end

    # When a file is provided, prefer the declared constant whose last segment
    # matches the file's basename (camelized). This handles wrappers like
    # `class User; module Idade; ...; end; end` in `user/idade.rb`, where the
    # outer class only re-opens an existing constant to define the inner one.
    def match_by_file_path
      expected = expected_leaf(@file_path)
      return nil unless expected

      @candidates.find { |c| c[:name].split("::").last == expected }
    end

    def expected_leaf(file)
      File.basename(file, ".rb").split("_").map(&:capitalize).join
    end

    def fallback_pick
      return nil if @candidates.empty?

      @candidates.find { |c| !c[:is_module] } || @candidates.first
    end

    def extract_const_name(node)
      RbsInfer::Analyzer.extract_constant_path(node) || node.to_s
    end
  end
end
