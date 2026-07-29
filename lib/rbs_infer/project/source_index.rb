require_relative "source_owners"

module RbsInfer::Project

  # Índice reverso de source files para lookup eficiente por nome de classe.
  # Evita a iteração O(n×m) ao buscar referências a classes nos source files.
  #
  # Na inicialização, lê todos os arquivos uma vez e constrói um mapa:
  #   CamelCaseToken → [file_paths]
  #
  # O lookup por classe é O(1) em vez de O(n).
  class SourceIndex
    # A method name as written after a dot — `Current.caderneta.qtde_por_vacina(v)`
    # contributes `caderneta` and `qtde_por_vacina`. Only explicit-receiver calls,
    # which is exactly the shape the constant index cannot see (see
    # `files_calling`); bare calls are covered by the mixin graph.
    RECEIVER_CALL = /\.\s*([a-z_][a-zA-Z0-9_]*[?!]?)/

    def initialize(source_files)
      @index = Hash.new { |h, k| h[k] = [] }
      @call_index = Hash.new { |h, k| h[k] = [] }
      source_files.each do |file|
        begin
          content = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end

        content.scan(RECEIVER_CALL).flatten.uniq.each do |method_name|
          @call_index[method_name] << file
        end
        # `_` faz parte do nome da constante: proxies de associação do
        # rbs_rails (`Post_Assignment`, `ActiveRecord_Associations_CollectionProxy`)
        # e código real tipo `HTTP_Client` são underscored. Sem o `_` na classe
        # de caracteres, o token era quebrado/perdido e o arquivo nunca era
        # indexado sob o nome cheio, degradando a resolução de `.new`/setter
        # externo pra `untyped`.
        content.scan(/\b([A-Z][a-zA-Z0-9_]*)\b/).flatten.uniq.each do |name|
          @index[name] << file
        end

        # A file whose class identity is not written in it (an ERB template is the body of
        # `ERBPostsEdit`, but never spells that) would otherwise be read and then never
        # selected as a caller. `SourceOwners` lets an extension state the convention.
        if (owner = RbsInfer::Project::SourceOwners.owner_class(file))
          short = owner.split("::").last
          @index[short] << file unless @index[short].include?(file)
        end
      end
      @index.each_value(&:freeze)
      @call_index.each_value(&:freeze)
    end

    # Retorna arquivos que provavelmente referenciam a classe.
    # Usa o último segmento do nome (ex: "Finance::Client" → "Client").
    def files_referencing(class_name)
      short_name = class_name.split("::").last
      @index[short_name] || EMPTY_ARRAY
    end

    # Files that call `method_name` on SOME receiver.
    #
    # `files_referencing` asks "does this file spell the class name?", which is the
    # wrong question for a call whose receiver is a value rather than the constant:
    # `Current.caderneta.qtde_por_fabricante_vacina(fabricante_vacina)` never writes
    # `Caderneta`, so the file was not a candidate caller and the argument's type was
    # never read — the parameter stayed `untyped` with no diagnostic
    # (felixefelip/rbs_infer#131). Views hit this constantly (an ERB template rarely
    # names a model), but it is not ERB-specific: any file reaching the target through
    # an ivar, a local, or a CurrentAttributes reader is invisible the same way.
    #
    # This is a CANDIDATE filter, not a match: `NewCallCollector#match_class?` still
    # has to resolve the receiver's type to the target before the call site counts.
    # Callers only ask about methods that TAKE parameters, which keeps the query off
    # the high-cardinality accessor names (`name`, `id`, `to_s`).
    def files_calling(method_name)
      @call_index[method_name] || EMPTY_ARRAY
    end

    EMPTY_ARRAY = [].freeze
    private_constant :EMPTY_ARRAY
  end

end
