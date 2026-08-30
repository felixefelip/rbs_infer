module RbsInfer::Signatures
  # Resolve tipos via RBS DefinitionBuilder, com suporte a genéricos/type parameters.
  # Ex: Post.find(id) → Post (resolve ClassMethods[::Post, ...])
  # Ex: Post::ActiveRecord_Relation.last → Post? (resolve genéricos)
  #
  # Extraído de MethodTypeResolver para manter responsabilidades separadas.

  class RbsDefinitionResolver
    KERNEL_TYPE_NAME = RBS::TypeName.parse("::Kernel")

    def initialize
      @rbs_builder = nil
      @rbs_builder_loaded = false
      # Memo for `method_owner`. Lives beside `@rbs_builder`, which is
      # fetched once per instance, so the cache can never outlive the environment
      # it was computed against — the invariant the README states for everything
      # derived from `SteepEnvironment`.
      @method_owners = {}
    end

    # `arg_types` is the call site's positional argument types (`["Integer"]` for
    # `age + 10`), or nil when the caller has none to offer. Without them an
    # overloaded method can only be guessed at, and the guess is DECLARATION
    # ORDER — which across reopens is load order and means nothing: `bigdecimal`'s
    # RBS reopens `Integer` with `def +: (BigDecimal) -> BigDecimal | ...`, so
    # `age + 10` resolved to `BigDecimal` and the emitted RBS contradicted its own
    # body.
    #
    # REQUIRED, not defaulted, per docs/engineering/required-threaded-deps.md: a
    # caller that forgets it is not loudly broken, it silently goes back to that
    # guess. Writing `arg_types: nil` is a caller SAYING it has no argument
    # information, which is a different statement from having said nothing — and
    # the sites that say it are the list of what is left to wire.
    def resolve_via_rbs_builder(kind, class_name, method_name, arg_types:, block_body_type: nil)
      return nil unless rbs_builder

      # Intersection types (e.g. `(Order & Order::Validated)` yielded by
      # `Relation::Methods[Model, Pk, ValidatedModel]#each`) need to be split
      # before lookup — `RBS::TypeName` only accepts a single nominal name.
      # Resolve right-to-left to match
      # `Steep::Interface::Builder.intersection_shape`'s later-wins merge.
      if (components = parse_intersection_components(class_name))
        components.reverse_each do |component|
          result = resolve_via_rbs_builder(kind, component, method_name, block_body_type: block_body_type,
                                                                        arg_types: arg_types)
          return result if result && result != "untyped"
        end
        return nil
      end

      type_name = build_rbs_type_name(class_name)
      return nil unless type_name
      return nil unless rbs_builder.env.class_decls.key?(type_name)

      defn = case kind
             when :singleton then rbs_builder.build_singleton(type_name)
             when :instance then rbs_builder.build_instance(type_name)
             end

      method = defn&.methods&.[](method_name.to_sym)
      return nil unless method

      if kind == :instance && method_name.to_s == "class" && kernel_class?(method)
        return kernel_class_return(type_name)
      end

      best = nil
      # One overload that the arguments single out answers the call; anything
      # else keeps the previous first-that-formats walk, so a caller with no
      # argument information is exactly as resolved as before.
      candidates = select_overload(method.defs, arg_types)&.then { |d| [d] } || method.defs
      candidates.each do |d|
        formatted = format_rbs_return_type(d.type.type.return_type, class_name)
        # For type variables (e.g. T in [T] { -> T } -> T), use the variable name
        # so it can be substituted by the type_params loop below
        if formatted.nil? && d.type.type.return_type.is_a?(RBS::Types::Variable) && d.type.type_params.any?
          formatted = d.type.type.return_type.name.to_s
        end
        next unless formatted
        if d.type.type_params.any?
          type_var_map = infer_type_vars_from_block(d.type, block_body_type: block_body_type)
          d.type.type_params.each do |tp|
            param_name = tp.respond_to?(:name) ? tp.name.to_s : tp.to_s
            replacement = type_var_map[param_name] || "untyped"
            formatted = formatted.gsub(/\b#{Regexp.escape(param_name)}\b/, replacement)
          end
        end
        return formatted unless formatted.include?("[self]")
        best ||= formatted
      end
      best
    rescue RBS::BaseError
      nil
    end

    # The one overload the call's arguments single out, or nil — "nil" meaning
    # "this walk has nothing to say", which leaves the previous behaviour in
    # place rather than replacing one guess with another.
    #
    # Matching is NOMINAL and exact, deliberately: a real answer is subtyping,
    # which needs a checker, and Steep already is that checker — the return pass
    # asks it for anything left `untyped`. What this has to be is SOUND, so it
    # only ever speaks when one overload names exactly the argument types the
    # call passes and no other overload does. Two matches, none, or a single
    # unknown argument all say nothing.
    def select_overload(defs, arg_types)
      return nil if arg_types.nil? || arg_types.empty? || arg_types.any?(&:nil?)

      matches = defs.select { |d| accepts_arguments?(d.type, arg_types) }
      matches.first if matches.size == 1
    end

    # A method type whose REQUIRED positionals are exactly these types. Anything
    # with optionals, a rest, trailing positionals or keywords is skipped: those
    # accept argument lists this comparison does not model, so calling them a
    # match would be the guess this method exists to avoid.
    def accepts_arguments?(method_type, arg_types)
      function = method_type.type
      return false unless function.is_a?(RBS::Types::Function)
      return false unless function.optional_positionals.empty? && function.trailing_positionals.empty?
      return false if function.rest_positionals
      return false unless function.required_keywords.empty? && function.optional_keywords.empty?
      return false if function.rest_keywords
      return false unless function.required_positionals.size == arg_types.size

      function.required_positionals.zip(arg_types).all? do |param, arg|
        normalize_type_name(param.type.to_s) == normalize_type_name(arg)
      end
    end

    # `::Integer` from RBS and `Integer` from the analyzer are one type.
    def normalize_type_name(name)
      name.to_s.strip.delete_prefix("::")
    end

    # Resolve the element type of a collection by looking up the `each` method's
    # block parameter type via RBS definitions.
    # Works for any class with `each` defined in RBS (Array, Set, ActiveRecord_Relation, etc.)
    def resolve_each_element_type(collection_type)
      return nil unless rbs_builder

      type_name = build_rbs_type_name(collection_type)
      return nil unless type_name
      return nil unless rbs_builder.env.class_decls.key?(type_name)

      defn = rbs_builder.build_instance(type_name)
      each_method = defn&.methods&.[](:each)
      return nil unless each_method

      each_method.defs.each do |d|
        block = d.type.block
        next unless block

        first_param = block.type.required_positionals.first
        next unless first_param

        formatted = format_rbs_return_type(first_param.type, collection_type)
        return formatted if formatted && formatted != "untyped"
      end

      nil
    rescue RBS::BaseError
      nil
    end

    # The class or module an instance method is DEFINED IN for `class_name`, walking
    # the RBS ancestor chain — superclasses and included modules alike — or nil when
    # the type has no such method (or isn't in the environment at all).
    #
    # This answers "whose method is this receiver calling?" for the case where the
    # answer is not readable from the receiver's NAME. Active Record is the extreme
    # example: `user.filters.from_params(...)` has a receiver typed
    # `User_Filter::ActiveRecord_Associations_CollectionProxy`, and the method it
    # reaches is defined two links up the chain, in
    # `Filter::GeneratedRelationMethods` — a per-association subclass of a proxy
    # that includes the delegating module. Neither link is a name the call site
    # spells, and both exist only in rbs_rails' RBS, so the mixin graph built from
    # the Ruby sources cannot see them either.
    # Does some OTHER file already declare `class_name#method_name` as a plain
    # (non-overloading) member? That is the precondition for emitting the overloading
    # form: `| ...` with nothing to overload is `InvalidOverloadMethodError`, and two
    # plain declarations are `DuplicatedMethodDefinitionError` — both of which poison the
    # whole environment rather than degrading.
    #
    # `excluding_suffix` drops the declaration WE are about to rewrite. Our own previous
    # output already declares the method, and confirming against it would be circular: a
    # method only we declare would gain `| ...` and then have nothing left to overload.
    # The suffix is `<source path>.rbs`, which is stable whatever `--output-dir` is.
    #
    # Only the same class counts. An ancestor's declaration is inheritance, which RBS
    # models as ordinary overriding and never rejects.
    def foreign_plain_declaration?(class_name, method_name, excluding_suffix: nil)
      return false unless rbs_builder

      type_name = build_rbs_type_name(class_name)
      return false unless type_name

      entry = rbs_builder.env.class_decls[type_name]
      return false unless entry

      entry.each_decl.any? do |decl|
        path = decl.location&.buffer&.name.to_s
        next false if excluding_suffix && path.end_with?(excluding_suffix)

        decl.members.any? do |member|
          member.is_a?(RBS::AST::Members::MethodDefinition) &&
            member.name.to_s == method_name.to_s &&
            !member.overloading?
        end
      end
    rescue RBS::BaseError
      false
    end

    # Which class or module OWNS the method a receiver of this type dispatches
    # to — the answer RBS's ancestor graph gives, for a receiver that never
    # spells the owner's name.
    #
    # Two chains, and the type says which: `Foo` is an instance, so the method
    # comes from `Foo`'s ancestors; `singleton(Foo)` is the module object
    # itself, whose methods come from `Foo`'s `def self.`s, from everything
    # `Foo` EXTENDS, and from `Module`/`Object` behind them. RBS builds both
    # (`AncestorBuilder#one_singleton_ancestors` is where `extended_modules`
    # is threaded in), so the singleton side costs nothing more than asking
    # `build_singleton` instead of `build_instance`.
    #
    # Without the singleton side every call site whose receiver reaches the
    # target through `extend` is invisible: `mod.send(:included, self)` in the
    # `Module#include` pseudo-code has a receiver typed as the includers'
    # singletons, and a hand-rolled `included` hook is reached from one of them
    # only by `extend` (felixefelip/rbs_infer#208).
    def method_owner(type_str, method_name)
      return nil unless rbs_builder

      key = [type_str, method_name]
      return @method_owners[key] if @method_owners.key?(key)

      @method_owners[key] = compute_method_owner(type_str, method_name)
    end

    # What `class_name` declares that `method_name` ACCEPTS: the parameter list
    # of each of its overloads, rendered the way RBS writes it and with the
    # `::` prefixes dropped the same way every other emitted type has them
    # dropped — `["(String label, ?Integer times) { (Integer) -> void }"]`.
    #
    # One entry per overload, in declaration order; `[]` when no declaration
    # answers, which is a caller's cue that it has nothing to copy.
    #
    # `kind` is which side to ask, exactly as `method_owner` means it, and the
    # definition is built rather than read off one declaration, so a method the
    # class only has through a superclass, an `include` or an `extend` answers
    # too.
    #
    # Rendered by RBS itself, via a method type whose return is replaced with
    # `void` and then cut off the end. Splitting the printed method type on
    # `->` cannot be done: a parameter can be a proc type and so can the return,
    # so neither the first nor the last arrow is reliably the one between them.
    def method_parameters(kind, class_name, method_name)
      return [] unless rbs_builder

      type_name = build_rbs_type_name(class_name)
      return [] unless type_name
      return [] unless rbs_builder.env.class_decls.key?(type_name)

      definition = kind == :singleton ? rbs_builder.build_singleton(type_name) : rbs_builder.build_instance(type_name)
      method = definition.methods[method_name.to_sym]
      return [] unless method

      method.defs.filter_map { |d| render_parameters(d.type) }.uniq
    rescue RBS::BaseError => e
      # An environment that cannot build this definition costs the caller the
      # parameters it came for, and the delegate it is emitting goes out as
      # `()`. Say so: a signature that quietly loses its parameters reads as an
      # answer, and the run has no other place this shows up.
      warn "[rbs_infer] could not read #{kind} parameters of #{class_name}##{method_name}: #{e.class}: #{e.message}"
      []
    end

    # RBS declares `Kernel#class` as `() -> Class`, which drops the one thing the
    # call states: WHICH class. Ruby's answer is the receiver's own singleton,
    # and so is the checker's — Steep rewrites this exact method per receiver
    # type when it builds an object's shape (`Interface::Builder#object_shape`
    # calls `replace_kernel_class`). Reading the declaration literally left
    # `self.class.normalize(x)` with a receiver typed `Class`, which names no
    # target, so the call site was invisible and `normalize`'s parameter was
    # typed by the OTHER call sites alone — narrower than the source shows
    # (felixefelip/rbs_infer#296).
    #
    # Only on the instance side: `Foo.class` is `Class`, exactly as declared,
    # which is what Steep's `singleton_shape` keeps.
    def kernel_class?(method)
      method.defs.any? do |type_def|
        member = type_def.member
        member.is_a?(RBS::AST::Members::MethodDefinition) &&
          member.name == :class &&
          type_def.defined_in == KERNEL_TYPE_NAME
      end
    end

    # `singleton(Foo)` for `Foo`. `type_name` is the name the lookup above
    # already resolved against the env, so it is a class and nothing else.
    def kernel_class_return(type_name)
      "singleton(#{type_name.to_s.sub(/\A::/, "")})"
    end

    def format_rbs_return_type(rbs_type, context_class = nil)
      case rbs_type
      when RBS::Types::Bases::Instance
        context_class&.sub(/\A::/, "")
      when RBS::Types::Bases::Self
        "self"
      when RBS::Types::Bases::Bool
        "bool"
      when RBS::Types::Bases::Void
        "void"
      when RBS::Types::Bases::Nil
        "nil"
      when RBS::Types::Bases::Any
        "untyped"
      when RBS::Types::Variable
        nil
      else
        rbs_type.to_s.gsub(/(^|[\[\(, |])::/) { $1 }
      end
    end

    # Parses an intersection-type string via `RBS::Parser.parse_type` and
    # returns the component names. Returns nil for non-intersection (or
    # unparseable) strings so the caller takes the legacy fast path.
    def parse_intersection_components(class_name)
      parsed = RBS::Parser.parse_type(class_name)
      return nil unless parsed.is_a?(RBS::Types::Intersection)
      parsed.types.map(&:to_s)
    rescue RBS::ParsingError
      nil
    end

    # The RBS type-parameter list of an existing class/module, rendered as a
    # string ("[unchecked out Elem]"), or "" when it has none or is unknown.
    #
    # Reopening a generic class (e.g. `Array.include M` → `class Array ...`)
    # must repeat its EXACT params: RBS validates arity plus
    # variance/bounds/defaults after renaming, raising
    # GenericParameterMismatchError otherwise — which poisons the whole Steep
    # environment, not just the one file (felixefelip/rbs_infer#38). Emitting
    # the params verbatim from the primary declaration guarantees the match.
    def type_param_string(class_name)
      return "" unless rbs_builder

      type_name = build_rbs_type_name(class_name)
      return "" unless type_name

      entry = rbs_builder.env.class_decls[type_name]
      return "" unless entry

      params = entry.type_params
      return "" if params.empty?

      "[#{params.map(&:to_s).join(", ")}]"
    rescue StandardError
      # A lookup failure must never break generation — fall back to no params
      # (correct for the overwhelmingly common non-generic case).
      ""
    end

    private

    def rbs_builder
      return @rbs_builder if @rbs_builder_loaded
      @rbs_builder_loaded = true
      @rbs_builder = SteepEnvironment.definition_builder
    end

    # Infere variáveis de tipo genérico a partir da assinatura do bloco.
    # Ex: [U] { (Nokogiri::XML::Node) -> U } → { "U" => "Nokogiri::XML::Node" }
    # Se block_body_type for fornecido (tipo real do corpo do bloco), usa-o
    # em vez do tipo do parâmetro do bloco.
    def infer_type_vars_from_block(method_type, block_body_type: nil)
      block = method_type.block
      return {} unless block

      block_return = block.type.return_type
      return {} unless block_return.is_a?(RBS::Types::Variable)

      # Se temos o tipo real do corpo do bloco, usar ele
      if block_body_type && block_body_type != "untyped"
        return { block_return.name.to_s => block_body_type }
      end

      # Fallback: inferir a partir do tipo do parâmetro do bloco
      first_param = block.type.required_positionals.first
      return {} unless first_param

      param_type = format_rbs_return_type(first_param.type)
      return {} unless param_type && param_type != "untyped"

      { block_return.name.to_s => param_type }
    end

    def build_rbs_type_name(class_name)
      RBS::TypeName.parse(class_name).absolute!
    end

    # `singleton(Foo)` has to be READ as a type rather than pattern-matched as a
    # string: `RBS::TypeName.parse` happily digests the spelling into a namespace
    # of `singleton(` and a name of `Foo)`, which no declaration answers to — a
    # silent nil where the answer was available.
    def compute_method_owner(type_str, method_name)
      parsed = RBS::Parser.parse_type(type_str)

      if parsed.is_a?(RBS::Types::ClassSingleton)
        method_owner_in(parsed.name.absolute!, method_name, :singleton)
      else
        # The instance side keeps reading the STRING, unchanged: taking
        # `parsed.name` here would also start answering for generic spellings
        # (`Array[String]`), which this lookup has always declined.
        method_owner_in(build_rbs_type_name(type_str), method_name, :instance)
      end
    rescue RBS::ParsingError, RBS::BaseError
      nil
    end

    # `method_type` minus its return type, as a string. See `method_parameters`.
    def render_parameters(method_type)
      function = method_type.type
      return "(?)" if function.is_a?(RBS::Types::UntypedFunction)

      void = RBS::Types::Bases::Void.new(location: nil)
      sentinel = RBS::MethodType.new(
        type_params: method_type.type_params,
        type: function.update(return_type: void),
        block: method_type.block,
        location: nil
      )
      rendered = sentinel.to_s.delete_suffix(" -> void")
      # Drop the leading `::` of every name, the way every other emitted type has
      # it dropped. Not `format_rbs_return_type`'s pattern: a parameter list puts
      # a name after `?`, `*`, `**` and `&` too, and `?::Integer times` came out
      # with the `::` still on it. What must survive is the `::` INSIDE a name
      # (`Example60::Labels`), which is the one preceded by an identifier.
      rendered.gsub(/(?<![A-Za-z0-9_:])::/, "")
    rescue RBS::BaseError => e
      # One overload that will not render drops out of the list; the others
      # still stand. Only `RBS::BaseError` — a shape this cannot print is a bug
      # here, not a fact about the project being read, and swallowing it would
      # hide it behind a delegate that merely looks under-typed.
      warn "[rbs_infer] could not render #{method_type}: #{e.class}: #{e.message}"
      nil
    end

    def method_owner_in(type_name, method_name, kind)
      return nil unless type_name
      # A spelling no declaration answers to (an alias, a class this run has not
      # seen) is rejected here rather than raised over.
      return nil unless rbs_builder.env.class_decls.key?(type_name)

      definition = kind == :singleton ? rbs_builder.build_singleton(type_name) : rbs_builder.build_instance(type_name)
      definition.methods[method_name.to_sym]&.defined_in&.to_s
    rescue RBS::BaseError
      nil
    end
  end
end
