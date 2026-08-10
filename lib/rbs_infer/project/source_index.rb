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

    # The WRITE form of the same shape: `record.channel = "none"` is a call to
    # `channel=`, and `RECEIVER_CALL` above stops before the `=` — so the file was
    # only ever indexed under `channel`, a name no caller asks about (a reader
    # takes no parameters, and `files_calling` is only asked about methods that
    # do). A writer-only method was therefore invisible unless its class happened
    # to have some OTHER parameterized method called in the same file, which is
    # what made the miss look intermittent.
    #
    # Op-assign counts: `record.count += 1` reads and writes. The `(?!=[=~>])`
    # tail keeps `==`, `=~` and `=>` out — those are reads of the getter, not
    # writes — and `!=` never matches because `!` is not among the operators.
    RECEIVER_WRITE = %r{\.\s*([a-z_][a-zA-Z0-9_]*)\s*(?:\|\||&&|\*\*|<<|>>|[-+*/%|&^])?=(?![=~>])}

    # A RECEIVERLESS call at the start of a line: `include Foo`, `helper :x`. The
    # `(?![ \t]*[=.])` tail keeps `include = 1` and `include.foo` out — the first is
    # no call, the second is the receiver form the index above already covers. `def
    # include(...)` never matches: the line starts with `def`.
    BARE_CALL_AT = ->(method_name) { /^[ \t]*#{Regexp.escape(method_name)}\b(?![ \t]*[=.])/ }

    # A literal-name `send` is a call to the method it NAMES, and that name is not written
    # after a dot — `RECEIVER_CALL` indexes such a file under `send`, a name no caller ever
    # asks about, so the call site was invisible and the method's parameter had none
    # (felixefelip/rbs_infer#205). Same class of miss as the bare `include` of #202, from
    # the other end: there the call had no receiver, here the name is not where a name goes.
    #
    # All three spellings, both literal forms, parens optional (`obj.send :stamp, "x"` is
    # the same call). The name tail allows `?!=` so a predicate and a writer are indexed
    # under the name they really have. An interpolated symbol cannot match: `:"` is not in
    # the character class, and neither is a bare variable, which is the undecidable case.
    SEND_CALL = /
      \b(?:__send__|public_send|send)\s*\(?\s*
      (?: :(?<sym>[a-z_][a-zA-Z0-9_]*[?!=]?)
        | (?<q>["'])(?<str>[a-z_][a-zA-Z0-9_]*[?!=]?)\k<q>
      )
    /x

    def initialize(source_files)
      @source_files = source_files
      @index = Hash.new { |h, k| h[k] = [] }
      @call_index = Hash.new { |h, k| h[k] = [] }
      @bare_call_index = {}
      source_files.each do |file|
        begin
          content = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end

        content.scan(RECEIVER_CALL).flatten.uniq.each do |method_name|
          @call_index[method_name] << file
        end
        content.scan(RECEIVER_WRITE).flatten.uniq.each do |method_name|
          @call_index["#{method_name}="] << file
        end
        content.scan(SEND_CALL).flatten.compact.uniq.each do |method_name|
          # The quote capture comes back too; it is never a method name.
          next if method_name == '"' || method_name == "'"

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

    # Files that call `method_name` with NO receiver.
    #
    # Deliberately scanned on demand instead of indexed with the two forms above: a
    # bare call has no `.` to key on, so indexing it means indexing nearly every
    # method name in the corpus — `puts`, `raise`, every macro of every DSL — to serve
    # the one question that needs it. The one asker is a target the ancestor graph puts
    # behind every object (`Module#include`), so the sweep is paid there and nowhere
    # else, and memoized per name.
    def files_with_bare_call(method_name)
      @bare_call_index[method_name] ||= begin
        pattern = BARE_CALL_AT.call(method_name)
        @source_files.select do |file|
          content = File.read(file)
          content.match?(pattern)
        rescue Errno::ENOENT, Errno::EACCES
          false
        end.freeze
      end
    end

    EMPTY_ARRAY = [].freeze
    private_constant :EMPTY_ARRAY
  end

end
