# frozen_string_literal: true

module RbsInfer::Inference
  # The locals of each method that ARE a reader of `self` wherever they are
  # read after their assignment — `_ = user` makes `_` `user` — by the rule the
  # checker's contracts inferrer roots a deref with
  # (`Steep::Contracts::AliasResolver.local_aliases`, felixefelip/steep#203):
  # one assignment, from a reader of `self`, no parameter of that name, no
  # write to the reader in the body.
  #
  # The rule is the checker's, so the two never disagree about what a local
  # is. It runs on the checker's own AST of the SAME source text this pipeline
  # parsed, so a method is matched by name and line, not by a position one
  # side may have shifted.
  module LocalSelfPaths
    module_function

    # `{ [method name, def line] => Set[local name] }`.
    def for(source)
      @cache ||= {}
      @cache[source] ||= compute(source)
    end

    def compute(source)
      buffer = ::Parser::Source::Buffer.new("(rbs_infer)", 1, source: source)
      root = Steep::Source.new_parser.parse(buffer)
      result = {}
      each_def(root) do |node|
        name = node.type == :defs ? node.children[1] : node.children[0]
        body = node.type == :defs ? node.children[3] : node.children[2]
        next unless body

        locals = Steep::Contracts::AliasResolver.local_aliases(body).keys.map(&:to_s)
        result[[name.to_s, node.loc.line]] = locals.to_set unless locals.empty?
      end
      result
    rescue StandardError
      {}
    end

    def each_def(node, &block)
      return unless node.is_a?(::Parser::AST::Node)

      yield node if node.type == :def || node.type == :defs
      node.children.each { |child| each_def(child, &block) }
    end
  end
end
