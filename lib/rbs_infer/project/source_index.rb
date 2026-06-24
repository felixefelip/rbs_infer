module RbsInfer

  # Índice reverso de source files para lookup eficiente por nome de classe.
  # Evita a iteração O(n×m) ao buscar referências a classes nos source files.
  #
  # Na inicialização, lê todos os arquivos uma vez e constrói um mapa:
  #   CamelCaseToken → [file_paths]
  #
  # O lookup por classe é O(1) em vez de O(n).
  class SourceIndex
    def initialize(source_files)
      @index = Hash.new { |h, k| h[k] = [] }
      source_files.each do |file|
        begin
          content = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
        content.scan(/\b([A-Z][a-zA-Z0-9]*)\b/).flatten.uniq.each do |name|
          @index[name] << file
        end
      end
      @index.each_value(&:freeze)
    end

    # Retorna arquivos que provavelmente referenciam a classe.
    # Usa o último segmento do nome (ex: "Finance::Client" → "Client").
    def files_referencing(class_name)
      short_name = class_name.split("::").last
      @index[short_name] || EMPTY_ARRAY
    end

    EMPTY_ARRAY = [].freeze
    private_constant :EMPTY_ARRAY
  end

end
