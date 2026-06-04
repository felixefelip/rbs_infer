# frozen_string_literal: true

require "prism"
require_relative "../../source_expanders"

module RbsInfer
  module Extensions
    module Rails
      # Desaçucara as macros `attribute :x` de subclasses de
      # ActiveSupport::CurrentAttributes em Ruby puro (pseudo-código),
      # para que o pipeline de inferência existente enxergue os accessors
      # como defs comuns (felixefelip/rbs_infer#19).
      #
      # O pseudo-código existe apenas em memória durante a geração — nunca
      # é carregado em runtime nem visto pelo `steep check` do app (que lê
      # o source real + o RBS gerado). A forma é a fonte mais simples que
      # produz os tipos certos, não uma simulação fiel do runtime:
      #
      #   attribute :user
      #   # vira:
      #   def user; @user; end
      #   def user=(value); @user = value; end
      #   def self.user; @user; end
      #   def self.user=(value); @user = value; end
      #
      # Os dois níveis (instância e singleton) leem/escrevem a MESMA ivar
      # de propósito: o pool de tipos fica unificado, espelhando o
      # `@attributes` compartilhado do CurrentAttributes real.
      #
      # Semântica do reset per-request expressa em código:
      # - sem `default:` → `@user` nunca é atribuída em `initialize`, então
      #   a regra de definite-initialization existente emite `User?`.
      # - com `default:` → o expander emite `def initialize; @user = <expr>; end`,
      #   tornando a ivar não-nilável e somando o default como fonte de tipo.
      #
      # `set`/`with` (set é alias de with) viram defs com kwargs que
      # escrevem as ivars diretamente, para que call-sites como
      # `Current.set(user: u)` alimentem o mesmo fluxo de inferência.
      module CurrentAttributesExpander
        SUPERCLASS_NAMES = [
          "ActiveSupport::CurrentAttributes",
          "::ActiveSupport::CurrentAttributes",
        ].freeze

        module_function

        # Retorna o source expandido, ou nil quando não há nada a expandir
        # (o arquivo não define subclasse de CurrentAttributes com `attribute`).
        def expand(source)
          return nil unless source.include?("CurrentAttributes")

          result = Prism.parse(source)
          return nil unless result.success?

          replacements = []
          RbsInfer::Analyzer.find_all_nodes(result.value) { |n| n.is_a?(Prism::ClassNode) }.each do |klass|
            next unless current_attributes_subclass?(klass)

            calls = attribute_calls_in(klass)
            next if calls.empty?

            replacements.concat(build_replacements(source, calls))
          end
          return nil if replacements.empty?

          apply_replacements(source, replacements)
        end

        def current_attributes_subclass?(klass)
          superclass = klass.superclass
          return false unless superclass

          SUPERCLASS_NAMES.include?(RbsInfer::Analyzer.extract_constant_path(superclass))
        end

        # Coleta os CallNodes `attribute ...` no nível do corpo da classe
        # (statements diretos, sem receiver). `attribute` dentro de defs ou
        # blocos não é o macro do CurrentAttributes.
        def attribute_calls_in(klass)
          body = klass.body
          statements = case body
                       when Prism::StatementsNode then body.body
                       when nil then []
                       else [body]
                       end

          statements.select do |stmt|
            stmt.is_a?(Prism::CallNode) && stmt.name == :attribute && stmt.receiver.nil? && stmt.arguments
          end
        end

        # Constrói as substituições para os `attribute` de UMA classe.
        # Cada call vira os 4 accessors dos seus atributos; a última call
        # ganha também `initialize` (quando há `default:`) e `set`/`with`
        # com kwargs de todos os atributos da classe.
        def build_replacements(source, calls)
          all_names = []
          defaults = {}

          parsed = calls.map do |call|
            names, call_defaults = parse_attribute_call(source, call)
            all_names.concat(names)
            defaults.merge!(call_defaults)
            [call, names]
          end

          parsed.map.with_index do |(call, names), idx|
            lines = names.flat_map { |name| accessor_defs(name) }
            if idx == parsed.length - 1
              lines.concat(initialize_def(defaults))
              lines.concat(set_with_defs(all_names))
            end

            indent = " " * call.location.start_column
            {
              start: call.location.start_offset,
              end: call.location.end_offset,
              text: lines.join("\n#{indent}"),
            }
          end
        end

        # `attribute :user, :account, default: -> { ... }` →
        # [["user", "account"], { "user" => "<source do default>" , ... }]
        # O default declarado vale para todos os atributos da mesma call
        # (mesmo comportamento do ActiveSupport).
        def parse_attribute_call(source, call)
          names = []
          default_source = nil

          call.arguments.arguments.each do |arg|
            case arg
            when Prism::SymbolNode
              names << arg.value.to_s
            when Prism::KeywordHashNode
              arg.elements.each do |elem|
                next unless elem.is_a?(Prism::AssocNode)
                next unless elem.key.is_a?(Prism::SymbolNode) && elem.key.value.to_s == "default"

                default_source = default_expression_source(source, elem.value)
              end
            end
          end

          defaults = default_source ? names.to_h { |n| [n, default_source] } : {}
          [names, defaults]
        end

        # Para lambdas/procs (`default: -> { User.new }`), o valor do
        # atributo é o RESULTADO do callable — usar o corpo. Para qualquer
        # outra expressão, o source literal.
        def default_expression_source(source, node)
          body = case node
                 when Prism::LambdaNode
                   node.body
                 when Prism::CallNode
                   node.block&.body if [:lambda, :proc].include?(node.name)
                 end

          expr = body || node
          slice = source.byteslice(expr.location.start_offset, expr.location.end_offset - expr.location.start_offset)
          multi_statement?(expr) ? "begin; #{slice}; end" : slice
        end

        def multi_statement?(node)
          node.is_a?(Prism::StatementsNode) && node.body.length > 1
        end

        def accessor_defs(name)
          [
            "def #{name}; @#{name}; end",
            "def #{name}=(value); @#{name} = value; end",
            "def self.#{name}; @#{name}; end",
            "def self.#{name}=(value); @#{name} = value; end",
          ]
        end

        def initialize_def(defaults)
          return [] if defaults.empty?

          ["def initialize"] +
            defaults.map { |name, expr| "  @#{name} = #{expr}" } +
            ["end"]
        end

        def set_with_defs(names)
          kwargs = names.map { |n| "#{n}: nil" }.join(", ")
          writes = names.map { |n| "@#{n} = #{n}" }.join("; ")

          # `&block` mantém a assinatura call-compatible com o uso real
          # (`Current.with(user: u) { ... }` restaura os atributos ao sair).
          # O corpo termina em `block.call` porque em runtime set/with
          # retornam o resultado do bloco — sem isso o return inferido
          # seria o valor atribuído, vazando pro tipo dos callers.
          ["set", "with"].map do |method|
            "def self.#{method}(#{kwargs}, &block); #{writes}; block.call; end"
          end
        end

        # Aplica as substituições de trás pra frente para não invalidar os
        # byte offsets das anteriores.
        def apply_replacements(source, replacements)
          out = source.dup
          replacements.sort_by { |r| -r[:start] }.each do |r|
            out = out.byteslice(0, r[:start]) + r[:text] + out.byteslice(r[:end]..)
          end
          out
        end
      end
    end
  end

  # Plugin de expansão de source (registrado por padrão: é puro Prism —
  # nada de Rails em runtime — e se auto-gateia pela superclasse).
  SourceExpanders.register(Extensions::Rails::CurrentAttributesExpander)
end
