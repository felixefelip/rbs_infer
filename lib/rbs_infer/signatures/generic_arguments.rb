# frozen_string_literal: true

module RbsInfer
  module Signatures
    # A class or module the environment declares generic, written with no
    # arguments (`@uncountables: Uncountables`, `include Enumerable`), is an
    # error in RBS, and an error in one signature file takes down the whole
    # environment. This writes `untyped` for each parameter, as the pipeline
    # already does for a superclass written with none. It reads names the way
    # `TypeNameQualifier` does, so it runs after it.
    class GenericArguments < TypeNameQualifier
      def apply
        _, _, decls = RBS::Parser.parse_signature(@rbs)
        @own = Set.new
        decls.each { |decl| collect_own(decl, "") }
        insertions(decls).reverse.each_with_object(@rbs.dup) { |(pos, text), out| out.insert(pos, text) }
      rescue RBS::ParsingError
        @rbs
      end

      private

      def insertions(decls)
        decls.flat_map { |decl| names_in_declaration(decl, []) }
             .filter_map do |name, location, context, node|
               text = bare?(node) && arguments(name, context)
               [location.end_pos, text] if text
             end
             .uniq.sort_by(&:first)
      end

      def bare?(node)
        node.respond_to?(:args) && node.args.empty? && !node.is_a?(RBS::Types::ClassSingleton)
      end

      def arguments(type_name, context)
        name = type_name.to_s.delete_prefix("::")
        name = resolve(name, context) || name unless type_name.absolute?
        params = @declared.call(name)
        params = params.type_params if params.respond_to?(:type_params)
        "[#{(["untyped"] * params.size).join(", ")}]" if params.is_a?(Array) && !params.empty?
      rescue StandardError
        nil
      end
    end
  end
end
