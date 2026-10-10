# frozen_string_literal: true

class RbsInfer::Inference::NewCallCollector < Prism::Visitor
  # A call site's arguments as `{ parameter name => type }`: onto the target's
  # `initialize` for a `.new` or a `super` (`for_initialize`), onto a method's
  # parameters for any other call (`for_params`).
  #
  # `value_type` types one argument node in the collector's current scope; the
  # checker's `expression_types` refine it (`argument_type`).
  class CallArguments
    def initialize(value_type:, expression_types:, init_positional_params:)
      @value_type = value_type
      @expression_types = expression_types
      @init_positional_params = init_positional_params
    end

    def for_initialize(call_node)
      return {} unless call_node.arguments

      arguments = call_node.arguments.arguments
      # A keyword never binds a positional parameter, even one of the same
      # name: `Kid.new(name: x)` onto `initialize(name)` passes the hash, not `x`.
      args = keyword_types(arguments.grep(Prism::KeywordHashNode), except: @init_positional_params)
      positionals = placeable(arguments).grep_v(Prism::KeywordHashNode)
      args.merge!(bind_positionals(positionals, @init_positional_params) { |arg| argument_type(arg) })
    end

    # Um `KeywordHashNode` normalmente é keyword — mas em Ruby 3, quando o método
    # NÃO aceita keywords, as keywords do call-site viram um Hash POSICIONAL
    # (`render partial: "x"` chega em `def render(target = nil, *rest)` como
    # `target = {partial: "x"}`). Reconhecemos isso quando nenhuma chave
    # corresponde a um parâmetro e ainda há slot posicional livre: sem isso o
    # argumento desaparece, e o parâmetro é tipado só pelos OUTROS call-sites —
    # estreito demais, não apenas impreciso.
    def for_params(call_node, param_names)
      return {} unless call_node.arguments

      arguments = call_node.arguments.arguments
      keyword = ->(arg) { arg.is_a?(Prism::KeywordHashNode) && !collapses_to_positional?(arg, param_names) }
      args = bind_positionals(placeable(arguments).reject(&keyword), param_names) do |arg|
        arg.is_a?(Prism::KeywordHashNode) ? hash_literal_type(arg) : argument_type(arg)
      end
      args.merge!(keyword_types(arguments.select(&keyword)))
    end

    # A non-empty hash literal whose keys are ALL plain symbols — the only shape a record
    # type can describe. Anything else (string/dynamic keys, `**splat`) keeps the generic
    # inferrer's `Hash[K, V]`, which handles those.
    def record_shaped?(node)
      return false unless node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      return false if node.elements.empty?

      node.elements.all? { |e| e.is_a?(Prism::AssocNode) && symbol_key(e.key) }
    end

    # `{ key: Type, ... }` for a literal keyword hash.
    def hash_literal_type(node)
      pairs = node.elements.filter_map do |e|
        next unless e.is_a?(Prism::AssocNode)

        key = symbol_key(e.key) or next
        "#{key}: #{@value_type.call(e.value) || "untyped"}"
      end

      return "Hash[Symbol, untyped]" if pairs.empty?

      "{ #{pairs.join(", ")} }"
    end

    private

    # A splat argument of unknown length does not say WHICH parameter gets what:
    # `stamp(*args)` may pass one argument or five, and what arrives is the array's
    # ELEMENTS, never the array. Recording `Array[untyped]` against the parameter is
    # not imprecise but wrong — `stamp` cannot receive an Array there — and a wrong
    # parameter type is worse than none, because it reads as an answer. Everything
    # after the splat is just as unplaced (felixefelip/rbs_infer#205).
    def placeable(arguments)
      arguments.take_while { |arg| !arg.is_a?(Prism::SplatNode) }
    end

    # A rest param takes EVERY remaining positional argument, so they all describe
    # the same parameter: they fold into one union instead of advancing, and the
    # splat's own type is that union — its ELEMENT type (`*T` means each argument
    # is a `T`).
    def bind_positionals(nodes, param_names)
      args = {}
      index = 0
      rest_types = []
      nodes.each do |node|
        break if index >= param_names.size

        type = yield node
        if splat_name(param_names[index])
          rest_types << type
          next
        end

        args[param_names[index]] = type
        index += 1
      end

      if (splat = splat_name(param_names[index])) && !rest_types.empty?
        args[splat] = RbsInfer::Inference::TypeMerger.union_types(rest_types.compact)
      end
      args
    end

    def keyword_types(hashes, except: [])
      hashes.flat_map(&:elements).each_with_object({}) do |elem, args|
        next unless elem.is_a?(Prism::AssocNode)

        key = symbol_key(elem.key)
        next if key.nil? || except.include?(key)

        args[key] = argument_type(elem.value)
      end
    end

    # The checker's answer for an argument the structural resolver could not
    # type (felixefelip/rbs_infer#157).
    #
    # `self.author_name = value&.full_name` is a call site the collector matches
    # and then throws away: `value` is the enclosing method's parameter and the
    # send is safe-navigated, which the structural path does not follow. The
    # argument came out `untyped`, the Analyzer drops `untyped` usages, and the
    # attribute stayed untyped though Steep types that expression `String?`.
    #
    # Mostly a fallback: the structural answer wins when it has one, since it
    # carries the naming conventions (a class name for `Klass.new`, a record for
    # a hash literal) that a checker type does not.
    #
    # The exception is nilability. The structural path resolves a call through
    # its DECLARATION — `Current.user` is `(User & User::Validated)?` because
    # that is what the signature says. A declaration is what holds where flow
    # can't be followed; at a position the checker has already proven non-nil,
    # its answer is the better one, and taking the declaration there hands the
    # callee's parameter a `nil` no call site can pass
    # (felixefelip/rbs_infer#186).
    def argument_type(arg)
      resolved = @value_type.call(arg)
      checker = expression_type(arg)

      return checker if narrowed_from?(resolved, checker)
      return resolved unless resolved.nil? || resolved == "untyped"

      checker || resolved
    end

    # Whether the two answers differ ONLY by nilability, with the checker on the
    # non-nil side. Deliberately not a general subtype test: this is the one
    # case where the checker is strictly better informed than the declaration,
    # and every other disagreement leaves the structural answer in charge.
    def narrowed_from?(declared, checked)
      return false unless declared && checked

      declared == RbsInfer::Signatures::RbsParserUtil.nilablize(checked)
    end

    def expression_type(node)
      # Keyed by the node's whole range: a receiver starts where its call does,
      # so a start position alone would let `ticket` answer for `ticket.holder`
      # (felixefelip/rbs_infer#168).
      type = @expression_types[RbsInfer::Signatures::SteepBridge.prism_expression_key(node.location)]

      # `self` is a real RBS type, but it means "the receiver of THIS method" —
      # so carrying it into ANOTHER method's parameter says the argument is a
      # Token when it is a controller. The checker answers `self` for a `self`
      # node; here that answer is unusable.
      type unless type == "self"
    end

    def splat_name(param_name) = RbsInfer::Inference::RestParamMarker.unmark(param_name)

    # Whether a keyword hash at the call site is really a positional Hash: no key names a
    # parameter, so the callee cannot be receiving them as keywords.
    def collapses_to_positional?(node, param_names)
      keys = node.elements.filter_map { |e| e.is_a?(Prism::AssocNode) ? symbol_key(e.key) : nil }
      return false if keys.empty?

      keys.none? { |k| param_names.include?(k) }
    end

    def symbol_key(node)
      node.unescaped if node.is_a?(Prism::SymbolNode)
    end
  end
end
