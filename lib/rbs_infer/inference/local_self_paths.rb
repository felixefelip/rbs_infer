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

    # `{ [method name, def line] => Set[local name] }`. `path` names the file
    # in the warning below.
    def for(source, path:)
      @cache ||= {}
      @cache[source] ||= compute(source, path)
    end

    def compute(source, path)
      buffer = ::Parser::Source::Buffer.new(path.to_s, 1, source: source)
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
    rescue ::Parser::SyntaxError => e
      # The source Prism parsed, refused by the checker's parser (a construct
      # its translation does not take). No local is then read as a reader,
      # which costs types and nothing else — said here, since nothing else
      # shows it. Any other error is a bug, and is left to surface.
      warn "[rbs_infer] could not read the locals of #{path}: #{e.class}: #{e.message}"
      {}
    end

    def each_def(node, &block)
      return unless node.is_a?(::Parser::AST::Node)

      yield node if %i[def defs].include?(node.type)
      node.children.each { |child| each_def(child, &block) }
    end
  end
end
