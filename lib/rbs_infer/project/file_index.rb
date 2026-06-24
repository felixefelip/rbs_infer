module RbsInfer
  # Índice de arquivos fonte construído uma vez no initialize do Analyzer.
  # Permite encontrar o arquivo correspondente a um class_path em O(1)
  # em vez de percorrer @source_files linearmente a cada busca.
  #
  # Para cada arquivo, indexa todos os sufixos do path (sem extensão):
  #   "app/models/account/import.rb" → chaves: "import", "account/import",
  #   "models/account/import", "app/models/account/import", etc.
  class FileIndex
    def initialize(source_files)
      @index = {}
      source_files.each do |file|
        base = file.delete_suffix(".rb")
        parts = base.split("/")
        parts.length.times do |i|
          suffix = parts[i..].join("/")
          @index[suffix] ||= file
        end
      end
    end

    # Retorna o arquivo correspondente ao class_path, ou nil se não encontrado.
    # Ex: find("account/import") → "/path/to/app/models/account/import.rb"
    def find(class_path)
      @index[class_path]
    end

    # Verifica se existe um arquivo para o class_path.
    def include?(class_path)
      @index.key?(class_path)
    end
  end
end
