# frozen_string_literal: true

module RbsInfer
  # Registry de plugins que reescrevem o source do arquivo-alvo ANTES do
  # parse (felixefelip/rbs_infer#19). Cada expander desaçucara macros em
  # pseudo-código Ruby para que o pipeline de inferência enxergue defs
  # comuns — a visão expandida existe só em memória durante a geração.
  #
  # O core não conhece nenhum framework: extensões (desta gem ou de
  # terceiros) se registram em require-time. Contrato de um expander:
  #
  #   expander.expand(source) #=> String (source expandido) | nil (no-op)
  #
  # Expanders devem ser idempotentes sobre o próprio output e baratos no
  # caminho no-op (gate por substring antes de parsear, como o
  # CurrentAttributesExpander faz com `CurrentAttributes`).
  module SourceExpanders
    @expanders = []

    module_function

    def register(expander)
      @expanders << expander unless @expanders.include?(expander)
      expander
    end

    def unregister(expander)
      @expanders.delete(expander)
    end

    def expanders
      @expanders.dup
    end

    # Aplica os expanders em cadeia (o output de um alimenta o próximo).
    # Retorna o source final expandido, ou nil quando nenhum alterou nada
    # — o caller usa nil para saber que não há visão expandida a expor.
    def apply(source)
      result = nil
      @expanders.each do |expander|
        expanded = expander.expand(result || source)
        result = expanded if expanded
      end
      result
    end
  end
end
