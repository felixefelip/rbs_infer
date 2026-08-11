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
        # @return [Hash, nil] `{ "anchor" => leaf, "annotations" => [lines] }`, or
        #   nil when nothing says what the module is mixed into.
        def entry_for(path:, module_name:, source:, mixin_index: nil)
          return nil if module_name.nil? || module_name.empty?

          hosts = hosts_for(path, module_name, mixin_index)
          extenders = mixin_index ? mixin_index.extenders_of(module_name) : []
          return nil if hosts.empty? && extenders.empty?

          anchor = module_name.split("::").last
          is_concern = source.include?("extend ActiveSupport::Concern")

          { "anchor" => anchor, "annotations" => annotations(module_name, hosts, extenders, is_concern) }
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
        def annotations(module_name, hosts, extenders, is_concern)
          instances = hosts.map { |host| "#{host} & #{module_name}" } +
                      extenders.map { |extender| "singleton(#{extender})" }
          instance = "# @type instance: #{union(instances)}"
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
