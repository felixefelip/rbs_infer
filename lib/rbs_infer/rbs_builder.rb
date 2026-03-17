module RbsInfer
  class RbsBuilder
    def initialize(target_class:, superclass_name:, namespace_classes: Set.new)
      @target_class = target_class
      @superclass_name = superclass_name
      @namespace_classes = namespace_classes
    end

    def build(members, init_arg_types, attr_types, optional_params = Set.new, method_param_types = {}, ivar_types: {})
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
      lines << "#{base_indent}class #{class_name}#{@superclass_name ? " < #{@superclass_name}" : ""}"

      # Emitir instance variables tipadas (@post: Post, @posts: ...)
      ivar_types.each do |name, type|
        lines << "#{member_indent}@#{name}: #{type}"
      end

      # Emitir include/extend para módulos incluídos (concerns)
      includes = members.select { |m| m.kind == :include }
      includes.each do |inc|
        lines << "#{member_indent}include #{inc.name}"
        if has_class_methods_module?(inc.name)
          lines << "#{member_indent}extend #{inc.name}::ClassMethods"
        end
      end

      current_visibility = :public
      has_private = members.any? { |m| m.visibility == :private }
      has_protected = members.any? { |m| m.visibility == :protected }

      # Agrupar por visibilidade: public -> protected -> private
      [:public, :protected, :private].each do |vis|
        vis_members = members.select { |m| m.visibility == vis && m.kind != :include }
        next if vis_members.empty?

        if vis != :public
          lines << ""
          lines << "#{member_indent}#{vis}"
          lines << ""
        end

        vis_members.each do |member|
          case member.kind
          when :method
            sig = member.signature
            # Substituir initialize com tipos inferidos dos call-sites
            if member.name == "initialize" && !init_arg_types.empty?
              sig = apply_inferred_init_types(sig, init_arg_types, optional_params)
            elsif method_param_types[member.name]
              sig = apply_inferred_param_types(sig, method_param_types[member.name])
            end
            lines << "#{member_indent}def #{sig}"
          when :attr_accessor, :attr_reader, :attr_writer
            sig = member.signature
            # Se o attr está untyped, tentar preencher via inferência do initialize
            if sig.end_with?(": untyped") && attr_types[member.name]
              sig = "#{member.name}: #{attr_types[member.name]}"
            end
            prefix = member.kind.to_s.sub("_", "_")
            lines << "#{member_indent}#{member.kind} #{sig}"
          end
        end
      end

      # Mailers: emitir método de classe send_mail (ActionMailer pattern)
      if mailer_class?
        send_mail = members.find { |m| m.kind == :method && m.name == "send_mail" }
        if send_mail
          lines << "#{member_indent}def self.#{send_mail.signature}"
        end
      end

      lines << "#{base_indent}end"
      modules.each_with_index do |_, i|
        lines << "#{"  " * (modules.size - 1 - i)}end"
      end

      lines.join("\n")
    end

    private

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
