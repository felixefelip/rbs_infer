module RbsInfer
  # Accumulates the observed types of an instance variable across all
  # writes (direct `@x = expr` and `self.x = expr` via attr_writer/accessor),
  # dedupes, and emits the union string used in the generated `.rbs`.
  #
  # Per felixefelip/rbs_infer#4 the emission rule is:
  #
  # - One non-nilable type: `T`.
  # - One nilable type: `T?`.
  # - Multiple non-nilable types: `T1 | T2 | ...`.
  # - Multiple types with nilability (any input was `T?`/`nil`, or
  #   `force_nilable: true`): `(T1 | T2 | ...)?`.
  #
  # Nilability has two sources:
  # 1. A write with RHS `nil` literal or type `T?` (intrinsic).
  # 2. The definite-initialization rule — caller passes `force_nilable: true`
  #    when no write was observed inside `initialize` (or at class-body
  #    scope).
  #
  # Dedupe is syntactic (whitespace-insensitive). Semantic simplifications
  # like `(A & B) | A → A` are intentionally NOT performed — the union
  # form is load-bearing for `steep#16` flow-sensitive narrowing, which
  # only dispatches when the declared type is a literal union.
  class IvarTypeSet
    IGNORABLE = %w[untyped bot].freeze

    def initialize
      @ordered = []
      @seen = {}
      @nilable = false
    end

    def add(type_str)
      return if type_str.nil?
      type_str = type_str.to_s.strip
      return if type_str.empty?
      return if IGNORABLE.include?(type_str)

      if type_str == "nil"
        @nilable = true
        return
      end

      if type_str.end_with?("?")
        @nilable = true
        return add(type_str.chomp("?"))
      end

      # Unions chegam como string única quando o tipo vem do Steep ou de
      # um RBS já gerado (e.g. `(User | (User & User::Validated) | nil)`
      # numa segunda geração). Achatar em componentes — união de uniões é
      # associativa, então isso preserva todos os componentes e mantém a
      # emissão estável entre gerações (fixpoint). NÃO é a simplificação
      # semântica proibida pelo steep#16 (`(A & B) | A → A`).
      if (components = parse_union_components(type_str))
        components.each { |c| add(c) }
        return
      end

      add_unique(type_str)
    end

    def empty?
      @ordered.empty? && !@nilable
    end

    # Emits the union string. Returns `nil` when nothing was collected and
    # `force_nilable` is false — caller should treat that as "no entry".
    def emit(force_nilable: false)
      nilable = @nilable || force_nilable

      return nil if @ordered.empty? && !nilable
      return "nil" if @ordered.empty?

      if @ordered.length == 1
        nilable ? "#{@ordered.first}?" : @ordered.first
      else
        body = @ordered.join(" | ")
        nilable ? "(#{body})?" : body
      end
    end

    private

    # Retorna os componentes de um union top-level (`A | B | nil`), ou nil
    # quando o tipo não é union (ou não parseia como RBS). Componentes
    # interseção mantêm parens (`(A & B)`) — preserva a forma emitida e a
    # chave de dedupe usadas pelos demais produtores de entradas.
    def parse_union_components(type_str)
      return nil unless type_str.include?("|")

      parsed = RBS::Parser.parse_type(type_str)
      return nil unless parsed.is_a?(RBS::Types::Union)

      parsed.types.map do |t|
        s = t.to_s
        t.is_a?(RBS::Types::Intersection) ? "(#{s})" : s
      end
    rescue RBS::ParsingError, RBS::BaseError
      nil
    end

    def add_unique(type_str)
      key = type_str.gsub(/\s+/, "")
      return if @seen[key]
      @seen[key] = true
      @ordered << type_str
    end
  end
end
