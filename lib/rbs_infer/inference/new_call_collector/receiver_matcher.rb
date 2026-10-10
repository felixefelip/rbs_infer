# frozen_string_literal: true

class RbsInfer::Inference::NewCallCollector < Prism::Visitor
  # Whether a receiver, as typed at the call site, reaches the target — and
  # under which `MethodKey` its arguments are filed.
  #
  # `namespace` is the lexically enclosing class at the call, against which a
  # relative receiver spelling is resolved (`relative_receiver_matches_target?`).
  class ReceiverMatcher
    def initialize(target_class:, method_owners:, defined_class_names:)
      @target_class = target_class.sub(/\A::/, "")
      # felixefelip/rbs_infer#159: `{ "deny" => "Example19::Responder" }` — the
      # target's methods that belong to a nested module, which is emitted in
      # place rather than as a target of its own, so its call sites are matched
      # against the OWNER's name instead of the enclosing target's.
      @method_owners = method_owners
      # FQNs of classes/modules defined in the file being scanned; disambiguates
      # a relative receiver from a same-simple-name class elsewhere (see
      # `relative_receiver_matches_target?`).
      @defined_class_names = defined_class_names
    end

    def match_class?(name, namespace:)
      receiver_components(name).any? { |component| match_class_branch?(component, namespace) }
    end

    # `{ key => [branches that reach it] }` for a receiver, in branch order.
    #
    # ONE key per branch of the receiver, not one for the whole receiver. The
    # branches of a union can reach different methods — `(singleton(Baz) |
    # singleton(BazOther)).bazingado` is `Foo`'s through `Baz`'s extend and
    # `BazOther`'s own `def self.` — and answering with the first match filed
    # the call site against one of them and left the other with nothing
    # (felixefelip/rbs_infer#231).
    #
    # The three matchers in their historical order — the two string comparisons
    # before the one that consults the RBS environment — applied to each branch
    # on its own. Only the owner and ancestry matches know the call reaches
    # something other than the target's own method, so only they qualify the key
    # they file under.
    def keys_by_branch(receiver_type, method_name, namespace:)
      return {} if receiver_type.nil?

      receiver_components(receiver_type).each_with_object({}) do |component, acc|
        key =
          if match_class_branch?(component, namespace)
            method_name
          else
            owner_match_key(component, method_name, namespace) || ancestry_match_key(component, method_name)
          end
        next unless key

        (acc[key] ||= []) << component
      end
    end

    # Does the handler this receiver would reach belong to the target?
    #
    # NOT "is the receiver the target": a subclass that adds nothing
    # (`class CsvImportJob < BaseImportJob; end`) still runs the target's
    # handler, and `CsvImportJob.perform_later(path)` is the only call site
    # `BaseImportJob#perform` has. Matching on identity discarded it and left the
    # parameter `untyped` — narrower than the truth, under a whole-program
    # assumption where a missed call site is a missed type.
    #
    # It is also what the ordinary path already does: `ancestry_match_key`
    # accepts a direct call when the OWNER is the target. This asks the same
    # question of the same resolver, so the two paths agree.
    #
    # The forward is reached on the class; the HANDLER is an instance method, so
    # ownership is asked of the instance side of whatever the receiver names.
    def reaches_target_method?(receiver_type, forwarded_to)
      receiver_components(receiver_type).any? do |component|
        owner = rbs_definition_resolver.method_owner(singleton_receiver(component) || component, forwarded_to)
        owner && owner.sub(/\A::/, "") == @target_class
      end
    end

    private

    def match_class_branch?(component, namespace)
      normalized_name = component.sub(/\A::/, "")
      return true if normalized_name == @target_class

      relative_receiver_matches_target?(normalized_name, @target_class, namespace)
    end

    # Every nominal type the receiver could hold at the moment of the call.
    #
    # An intersection is the marker-decorated shape (`Caderneta &
    # Caderneta::Validated`) — any component identifies the receiver. A union is
    # every branch the ivar was written with. And `T?` is `T`: the call is being
    # MADE on it, so at runtime it is a `T` or the program raises — the same
    # optimism `MethodTypeResolver#resolve` already applies when it drops the `?`
    # before looking a method up.
    #
    # Decomposing only the intersection is what silently dropped every
    # `Current.<attr>.method(arg)` call site: a CurrentAttributes reader is
    # honestly nilable (per-request reset), so its type arrives as
    # `(Caderneta & Caderneta::Validated)?` and the whole string was compared
    # against `Caderneta` (felixefelip/rbs_infer#131).
    def receiver_components(type_str)
      flatten_receiver_type(RBS::Parser.parse_type(type_str))
    rescue RBS::ParsingError, RBS::BaseError
      # A spelling RBS cannot parse still gets the legacy intersection split, so
      # nothing that matched before stops matching.
      intersection_components(type_str)
    end

    def flatten_receiver_type(type)
      case type
      when RBS::Types::Union, RBS::Types::Intersection
        type.types.flat_map { |t| flatten_receiver_type(t) }
      when RBS::Types::Optional
        flatten_receiver_type(type.type)
      when RBS::Types::Bases::Nil
        []
      else
        [type.to_s]
      end
    end

    # The call the two matchers above cannot see: `Responder.deny(self, "denied")`
    # where `deny` belongs to `Example19::Responder`, a nested MODULE. Such a
    # module is emitted inside its enclosing target's block rather than as a
    # target of its own (felixefelip/rbs_infer#22), so nothing ever asked about
    # its call sites and its parameters stayed `untyped` — while a nested CLASS
    # three lines away, being a target, had everything inferred.
    #
    # The receiver is matched against the OWNER here, not the enclosing target,
    # and only for a method that owner actually has.
    #
    # Returns the `MethodKey` of the owner's method the receiver reaches, or nil.
    # WHICH owner matched is the answer, not just whether one did: the usages are
    # filed under that key so a sibling homonym does not inherit the type
    # (felixefelip/rbs_infer#215).
    def owner_match_key(component, method_name, namespace)
      entries = @method_owners[method_name]
      return nil if entries.nil? || entries.empty?

      singleton = singleton_receiver(component)
      normalized = (singleton || component).sub(/\A::/, "")

      entries.each do |owner, kind|
        # `singleton(X)` is the one receiver spelling that says which SIDE of
        # the owner is being called: it is X's singleton, so it reaches X's
        # `def self.`, and reaches an instance method of a module X extends
        # only through the ancestry — which `ancestry_match?` answers off the
        # RBS, and which loses to a `def self.` of the same name anyway. A
        # bare `X` says nothing: `resolve_receiver_type` returns the same
        # string for a constant receiver (`Responder.deny`, a singleton call)
        # and for a value of type X (an instance call), so both kinds stay
        # eligible there.
        next if singleton && kind != :class_method
        next unless normalized == owner || relative_receiver_matches_target?(normalized, owner, namespace)

        return RbsInfer::Inference::MethodKey.for(method_name, owner: owner, kind: kind)
      end

      nil
    end

    # `"singleton(Example23::Baz)"` → `"Example23::Baz"`; nil for anything else.
    # `receiver_components` deliberately keeps a singleton type whole (it is one
    # nominal type, not a decomposable union), so the unwrapping happens here.
    def singleton_receiver(component)
      component[/\Asingleton\((.+)\)\z/, 1]
    end

    # Does the receiver reach the target's method through its ANCESTRY — a
    # superclass, a module it includes, a module it extends — rather than
    # through its name?
    #
    # `match_class?` and `owner_match?` above both compare NAMES, which is all the
    # sources can be asked. A receiver typed as the class that includes the target
    # module never spells that module, so every such call site was invisible and
    # the module's parameters stayed `untyped`. Active Record makes this the normal
    # case rather than the exotic one: it delegates a model's class methods to its
    # relations and proxies through `<Model>::GeneratedRelationMethods`, so
    # `user.filters.from_params(filter_params)` — a receiver typed
    # `User_Filter::ActiveRecord_Associations_CollectionProxy`, two ancestry links
    # away — is how those methods are actually called, while the only call site the
    # name-based match accepted was the AR-runtime pseudo-code's own
    # `::Filter.from_params(params)`, forwarding a parameter still being inferred.
    # `Filter.from_params` therefore read `(untyped params)` even though every real
    # caller passes an `ActionController::Parameters & …::Permitted`.
    #
    # Asked LAST, and only for a method the target declares: the two name-based
    # matches are string comparisons, this one consults the RBS environment.
    #
    # The RBS is also the only place that knows this — rbs_rails declares the
    # relation shapes and their `include`s in signatures, never in Ruby, so
    # `MixinIndex` (built from the sources' `include`s) cannot answer it. The
    # same holds for the SINGLETON side, which `method_owner` reads off the
    # same graph: `MixinIndex` records `include`/`prepend` and nothing else, so
    # a receiver that reaches the target by `extend` has no other oracle
    # (felixefelip/rbs_infer#208).
    #
    # Returns the `MethodKey` of the method the receiver reaches, or nil — the
    # bare name when the ancestry lands on the target itself, the owner's key
    # when it lands on one of the target's nested modules.
    #
    # That second case is the one `owner_match_key` deliberately leaves here: a
    # `singleton(X)` receiver reaches a nested module's INSTANCE method only
    # because X extends it, which is a fact of the ancestry and not of any name,
    # so only the RBS can answer it. Answering it against the target alone left
    # `Example24::Foo#bazingado` untyped — its one call site is
    # `module_included.bazingado(self)` with `module_included` a
    # `singleton(Example24::Baz)`, and `Baz` extends `Foo`
    # (felixefelip/rbs_infer#229).
    def ancestry_match_key(component, method_name)
      owner = method_owner_on_either_side(component, method_name) or return nil

      normalized_owner = owner.sub(/\A::/, "")
      return method_name if normalized_owner == @target_class

      entry = nested_owner_entry(normalized_owner, method_name) or return nil
      RbsInfer::Inference::MethodKey.for(method_name, owner: entry[0], kind: entry[1])
    end

    # The owner of `method_name` as reached from `component`, asking the
    # INSTANCE side first and the SINGLETON side after.
    #
    # A bare `Foo` receiver spelling does not say which side was called:
    # `resolve_receiver_type` returns the same string for a constant receiver
    # (`Filter.indexed_by_human_name(index)`, a singleton call) and for a value
    # of type `Filter` (an instance call). `owner_match_key` already treats both
    # kinds as eligible for such a spelling and says so; this matcher asked only
    # the instance side, so a class method reached through the SINGLETON
    # ancestry — the shape `extend`ing a concern's `ClassMethods` produces, i.e.
    # every `ActiveSupport::Concern` in the project — had no matcher at all, and
    # its parameters stayed `untyped` however precisely the call site typed them
    # (felixefelip/rbs_infer#293).
    #
    # The fallback is only reached when the instance side does NOT define the
    # name, and then the class object is the only receiver that can answer the
    # call — so the extra answer costs no precision. A spelling that already
    # says `singleton(Foo)` has stated its side and gets no second question.
    def method_owner_on_either_side(component, method_name)
      resolver = rbs_definition_resolver
      owner = resolver.method_owner(component, method_name)
      return owner if owner
      return nil if singleton_receiver(component)

      resolver.method_owner("singleton(#{component})", method_name)
    end

    # The target's nested owner the ancestry landed on, as `[owner, kind]`.
    #
    # The instance side wins a tie: reaching a nested module THROUGH the
    # ancestry — `include` onto the instances, `extend` onto the singleton —
    # always lands on its instance methods. Its `def self.` sits on the module's
    # own singleton, which only a receiver naming the module reaches, and
    # `owner_match_key` answers that one by name before this runs.
    def nested_owner_entry(owner_name, method_name)
      entries = @method_owners[method_name] or return nil

      matching = entries.select { |owner, _| owner == owner_name }
      matching.find { |_, kind| kind == :method } || matching.first
    end

    def rbs_definition_resolver
      @rbs_definition_resolver ||= RbsInfer::Signatures::RbsDefinitionResolver.new
    end

    # A relative receiver spelling (`Foo`, `Bar::Baz`) matches a target whose
    # full name ends with it (`Email` == `Academico::Aluno::Email`) — the
    # whole-program unique-simple-name assumption the analyzer relies on when
    # the receiver isn't fully qualified.
    #
    # The one exception: two classes sharing a simple name must not be
    # conflated. A bare `Foo` written *inside* `class Example3` is
    # `Example3::Foo` — Ruby resolves it against the lexical nesting — so it
    # must not match target `Example2::Foo`. We can prove this soundly whenever
    # the file being scanned itself defines the class the spelling resolves to:
    # if `Foo` resolves to `Example3::Foo` (a class defined in this file) under
    # the current nesting, it is that class, not the same-named target
    # elsewhere. Absent such a local definition we keep the unique-name
    # assumption (cross-file), which existing behaviour depends on.
    def relative_receiver_matches_target?(relative_name, target, namespace)
      return false unless target.end_with?("::#{relative_name}")

      resolved = resolve_relative_in_file(relative_name, namespace)
      resolved.nil? || resolved == target
    end

    # Ruby-style constant lookup of a relative name against the current lexical
    # nesting, restricted to classes DEFINED IN THIS FILE — the only
    # whole-program-agnostic signal available locally. Walks the nesting
    # innermost-first (`Example3::Foo` before top-level `Foo`) and returns the
    # first candidate this file defines, or nil when the file defines no such
    # class in scope.
    def resolve_relative_in_file(relative_name, namespace)
      return nil if @defined_class_names.empty?

      parts = namespace&.split("::") || []
      parts.length.downto(0) do |i|
        candidate = (parts[0, i] + [relative_name]).join("::")
        return candidate if @defined_class_names.include?(candidate)
      end
      nil
    end

    # Top-level components of an intersection type, respecting [] / ()
    # nesting so generics aren't split: "Caderneta & Caderneta::Validated"
    # → ["Caderneta", "Caderneta::Validated"]. A non-intersection type
    # returns itself. Outer enveloping parens are stripped first.
    def intersection_components(type_str) # rubocop:todo Metrics/MethodLength
      inner = strip_enveloping_parens(type_str.strip)
      components = []
      depth = 0
      buffer = +""
      inner.each_char do |char|
        case char
        when "[", "(" then depth += 1
                           buffer << char
        when "]", ")" then depth -= 1
                           buffer << char
        when "&"
          if depth.zero?
            components << buffer.strip
            buffer = +""
          else
            buffer << char
          end
        else buffer << char
        end
      end
      components << buffer.strip
      components.reject(&:empty?)
    end

    # Strips parens only when they envelop the whole string ("(A & B)" → "A &
    # B"); leaves "(A) & (B)" untouched.
    def strip_enveloping_parens(str)
      return str unless str.start_with?("(") && str.end_with?(")")

      depth = 0
      str.each_char.with_index do |char, i|
        depth += 1 if char == "("
        depth -= 1 if char == ")"
        return str if depth.zero? && i < str.length - 1
      end
      str[1..-2].strip
    end
  end
end
