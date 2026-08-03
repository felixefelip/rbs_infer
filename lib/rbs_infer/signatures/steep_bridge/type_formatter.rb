class RbsInfer::Signatures::SteepBridge
  class TypeFormatter
		class << self
			def format_type(steep_type)
				# `Steep::AST::Types::Logic::*` are internal types Steep uses for
				# predicate-narrowing flow analysis (e.g., the body of
				# `def x?; !@y.nil?; end` types as `Logic::Not`). They have no
				# valid RBS surface form — `to_s` emits `<% Steep::AST::Types::Logic::Not %>`,
				# which then leaks into generated RBS. Collapse all of them to
				# `bool` since that's the user-visible meaning of any predicate
				# return.
				return "bool" if steep_type.is_a?(Steep::AST::Types::Logic::Base)

				str = steep_type.to_s

				# Remove leading :: from all type names
				str = str.gsub(/(^|[\[\(, |])::/) { $1 }

				# Normalize record key format: { :sym => Type } → { sym: Type }
				str = str.gsub(/:(\w+) =>/, '\1:')

				# Normalize nilable types in nested contexts: (Type | nil) → Type?
				str = str.gsub(/\(([^|()]+) \| nil\)/) { "#{$1.strip}?" }
				str = str.gsub(/\(nil \| ([^|()]+)\)/) { "#{$1.strip}?" }

				# Normalize void out of union types: (void | T) → T?
				# void in a union means "return value not used in that branch", treat as nil
				if str =~ /\A\(/ && str.include?("void")
					parts = str.gsub(/\A\(|\)\z/, "").split(/\s*\|\s*/)
					parts.reject! { |p| p == "void" }
					parts.reject! { |p| p == "nil" }
					if parts.empty?
						return "void"
					elsif parts.size == 1
						return "#{parts.first}?"
					else
						return "(#{parts.join(" | ")})?"
					end
				end

				# Normalize (T | nil) to T?
				if str =~ /\A\((.+) \| nil\)\z/
					inner = $1.strip
					return "#{inner}?" unless inner.include?("|")
				end
				if str =~ /\A\(nil \| (.+)\)\z/
					inner = $1.strip
					return "#{inner}?" unless inner.include?("|")
				end

				str
			end

			def intrinsic_type_of(node, typing)
				case node.type
				when :nil
					Steep::AST::Builtin.nil_type
				when :str, :dstr
					Steep::AST::Builtin::String.instance_type
				when :int
					Steep::AST::Builtin::Integer.instance_type
				when :float
					Steep::AST::Builtin::Float.instance_type
				when :sym, :dsym
					Steep::AST::Builtin::Symbol.instance_type
				when :true
					Steep::AST::Types::Literal.new(value: true)
				when :false
					Steep::AST::Types::Literal.new(value: false)
				when :regexp
					Steep::AST::Builtin::Regexp.instance_type
				else
					typing.type_of(node: node) rescue nil
				end
			end
		end
  end
end
