module RbsInfer
  # Cache de parse compartilhado por análise.
  # Garante que cada arquivo seja lido do disco e parseado pelo Prism apenas uma vez.
  class ParseCache
    Entry = Struct.new(:source, :result, keyword_init: true)

    def initialize
      @cache = {}
    end

    # Retorna Entry com .source (String) e .result (Prism::ParseResult), ou nil se o arquivo não puder ser lido.
    def get(file)
      return @cache[file] if @cache.key?(file)

      @cache[file] = begin
        source = File.read(file)
        Entry.new(source: source, result: Prism.parse(source))
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end
    end
  end
end
