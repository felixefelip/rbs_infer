require_relative "../../project/self_type_annotators"

module RbsInfer
  module Extensions
    module Rails
      # Computes the `# @type self:` / `# @type instance:` annotation for a
      # concern/module, to be injected by Steep's generic
      # `Steep::Source::ModuleSelfTypes.inject` (felixefelip/rbs_infer#52).
      #
      # This is the Rails-aware half that used to live inside Steep: it knows
      # the path conventions (models / helpers / controller concerns), how a
      # module's hosts are resolved, and concern detection. Unlike the old Steep code
      # it does NOT camelize the file path to get the module name — the caller
      # passes the real name from the AST (`Analyzer#target_class`), so acronyms
      # (`SQLite`, `OAuth`) keep their declared casing.
      #
      # Registers on `RbsInfer::Project::SelfTypeAnnotators` so the core injects
      # it without naming this Rails extension (felixefelip/rbs_infer#60).
      module ModuleSelfTypeAnnotator
        HELPERS_PREFIX = "app/helpers/"
        CONTROLLER_CONCERNS_PREFIX = "app/controllers/concerns/"

        module_function

        # SelfTypeAnnotators plugin contract: the concern/module self-type as a
        # (possibly empty) list of inject-ready entries.
        def self_type_entries(path:, module_name:, source:, mixin_index: nil)
          entry = entry_for(path: path, module_name: module_name, source: source, mixin_index: mixin_index)
          entry ? [entry] : []
        end

        # @param path [String] source path (e.g. "app/models/search/record/sqlite.rb")
        # @param module_name [String] the real FQN from the AST (e.g. "Search::Record::SQLite")
        # @param source [String] the file's source (for concern detection)
        # @param mixin_index [MixinIndex, nil] the `include`s written in the sources
        # @param invoker_self_types [InvokerSelfTypes, nil] narrows the module-wide
        #   answer to the hosts that call each method; omitted, no `defs` is emitted
        # @return [Hash, nil] `{ "anchor" => leaf, "annotations" => [lines] }` plus
        #   `"defs" => { method => type }` where a method narrows, or nil when
        #   nothing says what the module is mixed into.
        def entry_for(path:, module_name:, source:, mixin_index: nil, invoker_self_types: nil)
          return nil if module_name.nil? || module_name.empty?

          hosts = hosts_for(path, module_name, mixin_index)
          extenders = mixin_index ? mixin_index.extenders_of(module_name) : []
          return nil if hosts.empty? && extenders.empty?

          anchor = module_name.split("::").last
          is_concern = source.include?("extend ActiveSupport::Concern")
          instance = instance_type(module_name, hosts, extenders)

          entry = { "anchor" => anchor, "annotations" => annotations(instance, module_name, hosts, is_concern) }
          defs = narrowed_defs(anchor, source, instance, invoker_self_types)
          entry["defs"] = defs if defs.any?
          paths = declared_paths(anchor, source, instance, invoker_self_types)
          entry["paths"] = paths if paths.any?
          entry
        end

        # `{ "bazinga" => [{ "when" => { param => type }, "self" => type }] }` —
        # which `self` goes with which argument, call site by call site.
        #
        # The per-method `defs` above says what `self` may be anywhere in the
        # method; this says which one goes with which path through it. Two
        # parameters of one method travel together across its call sites and no
        # RBS states that, so a call whose receiver is one of them is checked
        # against every branch at once and demands a `self` that satisfies all
        # of them — a type nothing is. felixefelip/steep#143 reads this and
        # checks such a call one branch at a time instead.
        #
        # Written only where it says something the per-method answer does not:
        # a method whose call sites all share one `self` is already covered.
        def declared_paths(anchor, source, instance, invoker_self_types)
          return {} if invoker_self_types.nil?

          declared = "(#{instance})"
          instance_methods(anchor, source).each_with_object({}) do |(name, params), acc|
            next if params.empty?

            entries = invoker_self_types.paths(method_name: name, declared: declared) or next
            written = entries.filter_map { |args, self_type| path_entry(args, params, self_type) }
            next unless written.size == entries.size

            acc[name] = written
          end
        end

        # One call site as the sidecar states it, or nil when it names an
        # argument this method has no parameter for — a call passing more than
        # the method takes cannot be what reached it.
        def path_entry(args, params, self_type)
          conditions = args.each_with_object({}) do |(index, type), acc|
            name = params[index] or return nil
            spelling = annotatable(type) or return nil
            acc[name] = spelling
          end
          return nil if conditions.empty?

          self_spelling = annotatable(self_type) or return nil
          { "when" => conditions, "self" => self_spelling }
        end

        # `{ "bazinga" => "singleton(::Example23::Bar)" }` — the methods of this
        # module whose `self` is narrower than the module's own.
        #
        # The module-wide line answers "what may `self` be anywhere in here",
        # which is the union over every host. A method only one host ever calls
        # runs with that one, and `InvokerSelfTypes` (felixefelip/rbs_infer#222)
        # already reads that off the call sites — it is what types the ARGUMENT
        # such a method passes. Emitting it here is what makes the two agree:
        # without it the body cannot pass its own `self` to a parameter typed
        # from that very narrowing (felixefelip/rbs_infer#221).
        #
        # Only the methods that actually narrow, so a module whose `self` is one
        # host, or whose methods nobody calls, writes nothing new.
        def narrowed_defs(anchor, source, instance, invoker_self_types)
          return {} if invoker_self_types.nil?

          declared = "(#{instance})"
          instance_method_names(anchor, source).each_with_object({}) do |name, acc|
            narrowed = invoker_self_types.narrow(method_name: name, declared: declared)
            next if narrowed == declared

            spelling = annotatable(narrowed) or next
            acc[name] = spelling
          end
        end

        # The one spelling of a type that Steep will accept in an annotation.
        #
        # `AnnotationParser#parse_type` re-reads the parsed node's own location
        # and demands it be byte-for-byte the string it was given. RBS drops a
        # redundant outer parenthesis from that location — `(A | B)` parses to a
        # union whose source is `A | B` — so a type RBS reads happily is a
        # syntax error in an annotation, reported against the ANNOTATED FILE.
        # `InvokerSelfTypes` wraps its answer because everywhere else that
        # answer lands is a type position where a bare `|` or `&` would bind
        # wrong; here it must not be wrapped, so ask RBS for the canonical form
        # rather than trying to spell it.
        #
        # nil unless RBS reads the WHOLE string. `parse_type` stops at the first
        # complete type and ignores the rest — `"not a type ("` comes back as
        # `not` — which is the very thing Steep's check catches, one file too
        # late. The input is either the canonical form or that form wrapped
        # once, because that is all `InvokerSelfTypes` produces; anything else
        # is a malformed narrowing and does not belong in a file Steep parses.
        def annotatable(type)
          canonical = RBS::Parser.parse_type(type).to_s
          stripped = type.strip
          canonical if stripped == canonical || stripped == "(#{canonical})"
        rescue RBS::ParsingError, RBS::BaseError
          nil
        end

        # The instance methods the module named `anchor` declares directly. A
        # `def self.` is excluded for the same reason Steep's placement skips
        # it: its `self` is the module object, which no invoker narrows.
        def instance_method_names(anchor, source)
          instance_methods(anchor, source).map(&:first)
        end

        # `[[name, positional parameter names], ...]` for those methods. The
        # parameters are what turns a call site's argument POSITIONS into the
        # names the sidecar states a path in.
        def instance_methods(anchor, source)
          node = find_scope(Prism.parse(source).value, anchor)
          body = node&.body
          return [] unless body.is_a?(Prism::StatementsNode)

          body.body.filter_map do |stmt|
            next unless stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?

            [stmt.name.to_s, positional_param_names(stmt)]
          end
        end

        def positional_param_names(node)
          params = node.parameters or return []

          names = []
          params.requireds.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:requireds)
          params.optionals.each { |p| names << p.name.to_s if p.respond_to?(:name) } if params.respond_to?(:optionals)
          names
        end

        def find_scope(node, anchor)
          return nil unless node.is_a?(Prism::Node)

          if (node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)) &&
             node.constant_path.respond_to?(:name) && node.constant_path.name.to_s == anchor
            return node
          end

          node.compact_child_nodes.each do |child|
            found = find_scope(child, anchor)
            return found if found
          end
          nil
        end

        # Every class a module is mixed into by `include`.
        #
        # The written `include`s come first: they are what the code says, while
        # the convention below is a guess from a file path. The guess stays as
        # the fallback for what no source shows — a helper is mixed in by Rails
        # itself, and nobody writes that `include` anywhere
        # (felixefelip/rbs_infer#163).
        #
        # `extenders` is not consulted here on purpose: the presumption answers
        # "which class includes this helper", and a module the sources show being
        # EXTENDED has already been answered by the code. Falling back for it
        # would put `ApplicationController` beside a host that is written down.
        def hosts_for(path, module_name, mixin_index)
          hosts = mixin_index ? mixin_index.hosts_of(module_name) : []
          return hosts if hosts.any?
          return [] if mixin_index && mixin_index.extenders_of(module_name).any?

          Array(presumed_host_for(path, module_name))
        end

        # The class a module is PRESUMED to be mixed into — nothing here reads
        # an `include`, which is why it only answers where no `include` exists
        # to read: Rails mixes helpers and controller concerns in itself, and
        # nobody writes those anywhere.
        #
        # There is deliberately no rule for a model concern. Its host is always
        # written down (`class Card; include Card::Entropic`), so guessing it
        # from the namespace only ever spoke where the guess was wrong: for
        # `Test::Filtrable` it answered `Test`, a directory; for the CLASSES
        # under `app/models/` — `Post::Archiver`, `Coupon::Code` — it claimed an
        # instance of one is also an instance of its namespace, which nothing
        # makes true (felixefelip/rbs_infer#163).
        def presumed_host_for(path, _module_name)
          path = path.to_s
          return "ApplicationController" if path.include?(HELPERS_PREFIX)
          return "ApplicationController" if path.include?(CONTROLLER_CONCERNS_PREFIX)

          nil
        end

        # An `include` and an `extend` of the same module produce `self`s of
        # different KINDS, and both are honest members of the same union: an
        # included module's instance method runs on an instance of the host
        # (`Card & Card::Entropic`), an extended one's runs on the host's class
        # object (`singleton(Bar)`) — no intersection with the module, because
        # the RBS reopen already writes `extend ::Foo` on that singleton.
        def instance_type(module_name, hosts, extenders)
          union(hosts.map { |host| "#{host} & #{module_name}" } +
                extenders.map { |extender| "singleton(#{extender})" })
        end

        def annotations(instance_type, module_name, hosts, is_concern)
          instance = "# @type instance: #{instance_type}"
          return [instance] unless is_concern

          # Only the `include` hosts: the `self` of a module's SINGLETON methods
          # when the module is extended would be `singleton(singleton(Bar))`,
          # which RBS cannot spell. A concern is included anyway — that is what
          # `ActiveSupport::Concern` is for — so this list is empty exactly when
          # there is nothing to say.
          selves = hosts.map { |host| "singleton(#{host}) & singleton(#{module_name})" }
          return [instance] if selves.empty?

          ["# @type self: #{union(selves)}", instance]
        end

        # Two hosts mean two possible `self`s — one at a time, which is a UNION.
        # Intersecting them says one object is both, which for two sibling
        # controllers is a type nothing has: method resolution against it
        # degrades and the module stops yielding facts at all. Measured on
        # Fizzy, where `Authentication` lost every postcondition it carried.
        # felixefelip/steep#130 is what makes a union usable as a self type.
        #
        # A single host is written bare, so the common case reads as it always
        # did and `&` never has to out-bind `|`.
        def union(parts)
          if parts.size == 1
            parts.first
          else
            parts.map { |part| "(#{part})" }.join(" | ")
          end
        end
      end

      RbsInfer::Project::SelfTypeAnnotators.register(ModuleSelfTypeAnnotator)
    end
  end
end
