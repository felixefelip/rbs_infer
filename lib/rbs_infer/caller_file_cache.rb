module RbsInfer
  # Cache de análise de arquivos caller.
  # ClassMemberCollector, ClassNameExtractor e DefCollector produzem resultados
  # estáveis por arquivo (independem da classe-alvo). Este cache garante que
  # cada um desses visitors roda no máximo uma vez por arquivo por análise,
  # mesmo que o arquivo seja acessado por build_init_param_types,
  # infer_attrs_from_call_sites e infer_wrapper_method_param_types.
  class CallerFileCache
    Analysis = Struct.new(:members, :class_name, :defs, keyword_init: true)

    def initialize(parse_cache)
      @parse_cache = parse_cache
      @cache = {}
    end

    def get(file)
      return @cache[file] if @cache.key?(file)
      @cache[file] = analyze(file)
    end

    private

    def analyze(file)
      entry = @parse_cache.get(file)
      return nil unless entry

      result = entry.result
      comments = result.comments
      lines = entry.source.lines

      member_collector = ClassMemberCollector.new(comments: comments, lines: lines)
      result.value.accept(member_collector)

      caller_ext = ClassNameExtractor.new
      result.value.accept(caller_ext)

      def_collector = DefCollector.new
      result.value.accept(def_collector)

      Analysis.new(
        members: member_collector.members,
        class_name: caller_ext.class_name,
        defs: def_collector.defs
      )
    end
  end
end
