module RbsInfer::Signatures
  class RbsBuilder
    # All keyword args are required: both call-sites always supply them, and
    # omitting any would be silently wrong (a missing `type_params` reopens a
    # generic class without its params → GenericParameterMismatchError; a
    # missing `is_module`/`namespace_classes` mis-renders the declaration).
    # Per docs/engineering/required-threaded-deps.md, that's "required", not
    # "defaulted".
    def initialize(target_class:, superclass_name:, namespace_classes:, is_module:, type_params:)
      @target_class = target_class
      @superclass_name = superclass_name
      @namespace_classes = namespace_classes
      @is_module = is_module
      # Generic type-parameter list ("[unchecked out Elem]") for the leaf
      # declaration when reopening a generic class; "" for the common
      # non-generic case (felixefelip/rbs_infer#38).
      @type_params = type_params
    end

    ATTR_KINDS = %i[attr_reader attr_writer attr_accessor].freeze

    def build(members, init_arg_types, attr_types, optional_params = Set.new, method_param_types = {}, ivar_types: {}, markers: [])
      members = reconcile_attrs_with_explicit_defs(members)
      parts = @target_class.split("::")
      class_name = parts.pop
      modules = parts

      base_indent = "  " * modules.size
      member_indent = base_indent + "  "

      lines = []
      modules.each_with_index do |mod, i|
        full_name = modules[0..i].join("::")
        keyword = @namespace_classes.include?(full_name) ? "class" : "module"
        lines << "#{"  " * i}#{keyword} #{mod}"
      end
      keyword = @is_module ? "module" : "class"
      lines << "#{base_indent}#{keyword} #{class_name}#{@type_params}#{!@is_module && @superclass_name ? " < #{qualify(@superclass_name)}" : ""}"

      # Each member group is emitted as its own block, separated from the
      # previous one by a single blank line (`add_group`). `body_start` marks
      # where the body begins so the first group never gets a leading blank.
      body_start = lines.size

      # Instance variables (@post: Post, @posts: ...)
      add_group(lines, body_start, ivar_types.map { |name, type| "#{member_indent}@#{name}: #{type}" })

      # Constants (NOME: Tipo) in source order — deterministic
      # (felixefelip/rbs_infer#37). `signature` already comes as "NOME: Tipo"
      # from the Analyzer (ConstantTypeResolver).
      direct_constants = members.select { |m| m.kind == :constant && m.owner.nil? }
      add_group(lines, body_start, direct_constants.map { |const| "#{member_indent}#{const.signature}" })

      # Nested modules defined in the target's body (felixefelip/rbs_infer#22).
      # Members collected with an `owner` come from a `module X ... end` inside
      # the class; we rebuild the container here instead of flattening them
      # (which would leave the `include X` dangling). This is also where the
      # CurrentAttributes `GeneratedAttributeMethods` is emitted — now from
      # parsing the pseudo-source, with the core unaware of the extension
      # (felixefelip/rbs_infer#19, #22).
      nested = []
      emit_parsed_nested_modules(nested, members, member_indent, attr_types, method_param_types)
      add_group(lines, body_start, nested)

      # Mixins: extend (e.g. ActiveSupport::Concern) + include (concerns),
      # each include optionally followed by its `::ClassMethods` extend.
      add_group(lines, body_start, mixin_lines(members, member_indent))

      # Class methods (def self.foo) and aliases. Instance aliases sit here
      # too — before the instance attrs/methods — preserving source order.
      add_group(lines, body_start, class_level_lines(members, member_indent, method_param_types))

      # Instance attrs and methods, grouped attrs-then-methods per visibility,
      # each block blank-separated.
      emit_instance_members(lines, body_start, members, member_indent, init_arg_types, attr_types, method_param_types, optional_params)

      # Mailers: emit the class method send_mail (ActionMailer pattern).
      if mailer_class?
        send_mail = members.find { |m| m.kind == :method && m.name == "send_mail" }
        if send_mail
          add_group(lines, body_start, ["#{member_indent}def self.#{RbsInfer::Signatures::RbsParserUtil.parenthesize_return_type(send_mail.signature)}"])
        end
      end

      # Marker classes for cross-receiver narrowing (felixefelip/rbs_infer#11).
      # Each becomes a nested `class AfterXxx ... end` with attr_reader
      # overrides — Steep intersects the receiver with it after the call via
      # `unconditional.self` in the sidecar. Each marker is its own group.
      markers.each do |marker|
        add_group(lines, body_start, marker_lines(marker, member_indent))
      end

      lines << "#{base_indent}end"
      modules.each_with_index do |_, i|
        lines << "#{"  " * (modules.size - 1 - i)}end"
      end

      "#{lines.join("\n")}\n"
    end

    private

    # Appends `group_lines` as a member block, preceded by a single blank line
    # when the body already has content (never right after the `class X`
    # opener, and never doubling an existing blank). A nil/empty group is a
    # no-op, so a blank is only ever spent on a group that actually emits.
    def add_group(lines, body_start, group_lines)
      return if group_lines.nil? || group_lines.empty?

      lines << "" if lines.size > body_start && !lines.last.to_s.empty?
      lines.concat(group_lines)
    end

    # `extend X` (standalone) then each `include X`, an include optionally
    # followed by its `extend X::ClassMethods`.
    def mixin_lines(members, indent)
      out = []
      members.select { |m| m.kind == :extend && m.owner.nil? }.each do |ext|
        out << "#{indent}extend #{qualify(ext.name)}"
      end
      members.select { |m| m.kind == :include && m.owner.nil? }.each do |inc|
        qualified = qualify(inc.name)
        out << "#{indent}include #{qualified}"
        out << "#{indent}extend #{qualified}::ClassMethods" if has_class_methods_module?(inc.name)
      end
      out
    end

    # `def self.foo` singletons, then singleton and instance aliases. Aliases
    # resolve the original method's type natively via RBS `alias`
    # (felixefelip/rbs_infer#63); singletons prefix both names with `self.`.
    # Instance aliases live here (before the instance attrs/methods) to
    # preserve the historical source order.
    def class_level_lines(members, indent, method_param_types)
      out = []
      members.select { |m| m.kind == :class_method && m.owner.nil? }.each do |member|
        sig = member.signature
        # Param types inferred from call-sites also apply to singletons
        # (`Current.user = x` → `def self.user=: (User? value)`) —
        # felixefelip/rbs_infer#19.
        sig = apply_inferred_param_types(sig, method_param_types[member.name]) if method_param_types[member.name]
        out << "#{indent}def self.#{RbsInfer::Signatures::RbsParserUtil.parenthesize_return_type(sig)}"
      end
      members.select { |m| m.kind == :singleton_alias && m.owner.nil? }.each do |a|
        out << "#{indent}alias self.#{a.name} self.#{a.old_name}"
      end
      members.select { |m| m.kind == :alias && m.owner.nil? }.each do |a|
        out << "#{indent}alias #{a.name} #{a.old_name}"
      end
      out
    end

    NON_INSTANCE_KINDS = %i[include extend class_method constant alias singleton_alias].freeze

    # Instance attrs and methods, in visibility order (public, protected,
    # private). RBS has no `protected`, so those are emitted keyword-less like
    # public. Within each visibility the attrs form one block and the methods
    # another, so an attr group and a method group are blank-separated
    # (`attr_reader x` / `def foo`). `private` introduces its section with the
    # keyword, itself blank-separated from what precedes and follows it.
    def emit_instance_members(lines, body_start, members, indent, init_arg_types, attr_types, method_param_types, optional_params)
      %i[public protected private].each do |vis|
        vis_members = members.select { |m| m.visibility == vis && m.owner.nil? && !NON_INSTANCE_KINDS.include?(m.kind) }
        next if vis_members.empty?

        if vis == :private
          lines << "" if lines.size > body_start && !lines.last.to_s.empty?
          lines << "#{indent}private"
        end

        attrs, methods = vis_members.partition { |m| ATTR_KINDS.include?(m.kind) }
        add_group(lines, body_start, render_members(attrs, indent, init_arg_types, attr_types, method_param_types, optional_params))
        add_group(lines, body_start, render_members(methods, indent, init_arg_types, attr_types, method_param_types, optional_params))
      end
    end

    def render_members(members, indent, init_arg_types, attr_types, method_param_types, optional_params)
      members.filter_map { |m| render_value_member(m, indent, init_arg_types, attr_types, method_param_types, optional_params) }
    end

    # `attr_accessor :x` declares `x` and `x=`; `attr_reader`/`attr_writer`
    # declares one of them. When the same class ALSO defines that method
    # explicitly (`def x=`), Ruby lets the later definition win — but RBS has
    # no such rule and rejects the duplicate ("Non-overloading method
    # definition of `x=` cannot be duplicated"). Reconcile by dropping the
    # generated half an explicit `def` replaces: downgrade an accessor to the
    # surviving reader/writer, or drop the attr entirely when both halves are
    # overridden.
    #
    # Scoped to the same owner: a `def x=` in the class legitimately overrides
    # an `attr_accessor :x` mixed in from a nested module, and RBS models that
    # as ordinary inheritance, not a duplicate — those must NOT reconcile.
    def reconcile_attrs_with_explicit_defs(members)
      defs_by_owner = Hash.new { |h, k| h[k] = Set.new }
      members.each { |m| defs_by_owner[m.owner] << m.name if m.kind == :method }

      members.flat_map do |m|
        next [m] unless ATTR_KINDS.include?(m.kind)

        kind = surviving_attr_kind(m, defs_by_owner[m.owner])
        if kind.nil?
          []
        elsif kind == m.kind
          [m]
        else
          [m.dup.tap { |copy| copy.kind = kind }]
        end
      end
    end

    # The attr kind left after an explicit `def name` / `def name=` replaces
    # part of what the attr would generate, or nil when nothing survives.
    def surviving_attr_kind(member, explicit_defs)
      reader_overridden = explicit_defs.include?(member.name)
      writer_overridden = explicit_defs.include?("#{member.name}=")

      case member.kind
      when :attr_reader then reader_overridden ? nil : :attr_reader
      when :attr_writer then writer_overridden ? nil : :attr_writer
      when :attr_accessor
        if reader_overridden && writer_overridden then nil
        elsif writer_overridden then :attr_reader
        elsif reader_overridden then :attr_writer
        else :attr_accessor
        end
      end
    end

    # Renders a single value member (method / attr_*) as one RBS line, or
    # nil for other kinds. Shared between the class body and nested-module
    # emission (felixefelip/rbs_infer#22).
    def render_value_member(member, indent, init_arg_types, attr_types, method_param_types, optional_params)
      case member.kind
      when :method
        sig = member.signature
        if member.name == "initialize" && !init_arg_types.empty?
          sig = apply_inferred_init_types(sig, init_arg_types, optional_params)
        elsif method_param_types[member.name]
          sig = apply_inferred_param_types(sig, method_param_types[member.name])
        end
        "#{indent}def #{RbsInfer::Signatures::RbsParserUtil.parenthesize_return_type(sig)}"
      when :attr_accessor, :attr_reader, :attr_writer
        sig = member.signature
        sig = "#{member.name}: #{attr_types[member.name]}" if sig.end_with?(": untyped") && attr_types[member.name]
        "#{indent}#{member.kind} #{sig}"
      end
    end

    # Reconstructs `module X ... end` blocks for members collected with an
    # `owner` (parsed from a nested module inside the target class). The
    # parsed `include X` is emitted separately as a direct member, so the
    # module declaration here gives that include a real target — no
    # dangling mixin (felixefelip/rbs_infer#22).
    def emit_parsed_nested_modules(lines, members, member_indent, attr_types, method_param_types)
      owned = members.reject { |m| m.owner.nil? }
      return if owned.empty?

      owned.group_by(&:owner).each do |owner, mod_members|
        inner_indent = member_indent + "  "
        lines << "#{member_indent}module #{owner}"

        mod_members.select { |m| m.kind == :constant }.each do |const|
          lines << "#{inner_indent}#{const.signature}"
        end
        mod_members.select { |m| m.kind == :include }.each do |inc|
          lines << "#{inner_indent}include #{qualify(inc.name)}"
        end
        mod_members.select { |m| m.kind == :extend }.each do |ext|
          lines << "#{inner_indent}extend #{qualify(ext.name)}"
        end
        mod_members.select { |m| m.kind == :class_method }.each do |m|
          lines << "#{inner_indent}def self.#{RbsInfer::Signatures::RbsParserUtil.parenthesize_return_type(m.signature)}"
        end
        mod_members.select { |m| m.kind == :singleton_alias }.each do |a|
          lines << "#{inner_indent}alias self.#{a.name} self.#{a.old_name}"
        end
        mod_members.select { |m| m.kind == :alias }.each do |a|
          lines << "#{inner_indent}alias #{a.name} #{a.old_name}"
        end
        mod_members.each do |m|
          line = render_value_member(m, inner_indent, {}, attr_types, method_param_types, Set.new)
          lines << line if line
        end

        lines << "#{member_indent}end"
      end
    end

    # Lines for one marker class (`class AfterXxx ... end`). The blank
    # separating it from the preceding group is added by `add_group`.
    def marker_lines(marker, member_indent)
      override_indent = member_indent + "  "
      out = ["#{member_indent}class #{marker.marker_name}"]
      marker.overrides.sort_by { |name, _| name }.each do |ivar_name, type_str|
        out << "#{override_indent}attr_reader #{ivar_name}: #{type_str}"
      end
      out << "#{member_indent}end"
      out
    end

    # Qualifica nomes de tipo que seriam ambíguos no contexto do namespace gerado.
    # Ex: dentro de "class Account { module Storage { ... } }", um include "Storage::Totaled"
    # seria resolvido como Account::Storage::Totaled em vez de ::Storage::Totaled.
    def qualify(type_name)
      return type_name if type_name.start_with?("::")
      all_parts = @target_class.split("::")
      first = type_name.split("::").first
      all_parts.include?(first) ? "::#{type_name}" : type_name
    end

    MAILER_BASES = %w[ApplicationMailer ActionMailer::Base].freeze

    def mailer_class?
      MAILER_BASES.include?(@superclass_name)
    end

    # Substitui parâmetros `untyped` na assinatura por tipos inferidos
    # Ex: "publicar_evento: (aluno: untyped) -> untyped" com {aluno: "Entity"}
    #   → "publicar_evento: (aluno: Entity) -> untyped"
    # Também suporta positional: "notify: (untyped user, untyped message) -> ..."
    #   → "notify: (User user, String message) -> ..."
    def apply_inferred_param_types(signature, param_types)
      param_types.each do |param_name, type|
        # Keyword: ?param_name: untyped → ?param_name: Type
        signature = signature.gsub(/(\??)#{Regexp.escape(param_name)}:\s*untyped/, "\\1#{param_name}: #{type}")
        # Positional: untyped param_name → Type param_name
        signature = signature.gsub(/\buntyped\s+#{Regexp.escape(param_name)}\b/, "#{type} #{param_name}")
      end
      signature
    end

    # Substitui tipos de parâmetros do initialize preservando posicional vs keyword
    # Ex: "initialize: (untyped post, ?notifier: untyped) -> untyped" com {post: "Post"}
    #   → "initialize: (Post post, ?notifier: untyped) -> void"
    def apply_inferred_init_types(signature, init_arg_types, optional_params)
      init_arg_types.each do |param_name, type|
        # Keyword: ?param_name: untyped → ?param_name: Type
        signature = signature.gsub(/(\??)#{Regexp.escape(param_name)}:\s*untyped/, "\\1#{param_name}: #{type}")
        # Positional: untyped param_name → Type param_name
        signature = signature.gsub(/\buntyped\s+#{Regexp.escape(param_name)}\b/, "#{type} #{param_name}")
      end
      # Normalizar return type do initialize para void
      signature = signature.sub(/->\s*untyped\s*$/, "-> void")
      signature
    end

    # Verifica se o módulo incluído tem um sub-módulo ClassMethods em .gem_rbs_collection/
    def has_class_methods_module?(module_name)
      parts = module_name.split("::")
      first = parts.first

      gem_hints = [
        first.downcase,
        first.gsub(/([a-z])([A-Z])/, '\1_\2').downcase,
        first.gsub(/([a-z])([A-Z])/, '\1-\2').downcase,
      ].uniq

      rbs_files = gem_hints.flat_map { |hint| Dir[".gem_rbs_collection/#{hint}/**/*.rbs"] }.uniq
      return false if rbs_files.empty?

      rbs_files.each do |file|
        content = File.read(file)
        next unless content.include?(parts.last)
        return true if RbsParserUtil.has_class_methods_submodule?(content, module_name)
      end

      false
    end
  end
end
