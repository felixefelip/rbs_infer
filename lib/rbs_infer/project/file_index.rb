module RbsInfer::Project
  # Índice de arquivos fonte construído uma vez no initialize do Analyzer.
  # Permite encontrar o arquivo correspondente a um class_path em O(1)
  # em vez de percorrer @source_files linearmente a cada busca.
  #
  # Para cada arquivo, indexa todos os sufixos do path (sem extensão):
  #   "app/models/account/import.rb" → chaves: "import", "account/import",
  #   "models/account/import", "app/models/account/import", etc.
  class FileIndex
    def initialize(source_files)
      @index = Hash.new { |h, k| h[k] = [] }
      source_files.each do |file|
        base = file.delete_suffix(".rb")
        parts = base.split("/")
        parts.length.times do |i|
          suffix = parts[i..].join("/")
          @index[suffix] << file
        end
      end
      @index.each_value(&:freeze)
    end

    # Retorna o arquivo correspondente ao class_path, ou nil se não encontrado.
    # Ex: find("account/import") → "/path/to/app/models/account/import.rb"
    def find(class_path)
      candidates(class_path).first
    end

    # Every file whose path ends in `class_path`, nearest match first.
    #
    # A suffix is not unique: `app/models/account/export.rb` and
    # `app/models/export.rb` both answer to "export", and the shorter path — the
    # one that actually declares the top-level `Export` — is not necessarily the
    # one indexed first. `find` therefore cannot be trusted to have picked the
    # file that declares the class asked for; a caller that can TELL (it parses
    # the file and compares the declared name) walks the candidates instead of
    # concluding the class does not exist (felixefelip/rbs_infer#185).
    #
    # Ordered by path depth so the least-nested file — the conventional home of
    # a top-level constant — is tried first.
    def candidates(class_path)
      files = @index.fetch(class_path, EMPTY)
      return files if files.size < 2

      # The path breaks ties so the order cannot vary between runs (`sort_by` is
      # not stable), which a generator writing files must be able to rely on.
      files.sort_by { |file| [file.count("/"), file] }
    end

    # Verifica se existe um arquivo para o class_path.
    def include?(class_path)
      @index.key?(class_path)
    end

    EMPTY = [].freeze
  end
end
