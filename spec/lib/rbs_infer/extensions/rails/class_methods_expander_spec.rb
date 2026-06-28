# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs"
require "rbs_infer/extensions/rails/class_methods_expander"
require_relative "../../../../support/temp_file_helpers"

RSpec.describe RbsInfer::Extensions::Rails::ClassMethodsExpander do
  include TempFileHelpers

  def expand(source)
    described_class.expand(source)
  end

  describe ".expand" do
    it "returns nil for sources without class_methods" do
      expect(expand(<<~RUBY)).to be_nil
        module Greetable
          def greet; "hi"; end
        end
      RUBY
    end

    it "returns nil when class_methods is called with arguments (not the Concern DSL)" do
      expect(expand(<<~RUBY)).to be_nil
        class Registry
          def class_methods(klass)
            yield klass
          end
        end
      RUBY
    end

    it "rewrites `class_methods do ... end` into a nested ClassMethods module" do
      expanded = expand(<<~RUBY)
        module Greetable
          extend ActiveSupport::Concern

          class_methods do
            def banner
              "hi"
            end
          end
        end
      RUBY

      expect(expanded).to include("module ClassMethods")
      expect(expanded).to include("def banner")
      expect(expanded).not_to include("class_methods do")
    end
  end

  # End-to-end: drive the real Analyzer over a Concern source and assert,
  # against the *parsed* RBS, that `banner` lands inside `module ClassMethods`
  # while the concern's own instance method stays a direct member.
  describe "through the Analyzer pipeline" do
    def generated_rbs(source)
      with_temp_files("greetable.rb" => source) do |_dir, paths|
        RbsInfer::Analyzer.new(target_file: paths.first, source_files: paths).generate_rbs
      end
    end

    def parse_decls(rbs)
      RBS::Parser.parse_signature(rbs).last
    end

    it "emits `class_methods do` defs as instance methods of a nested ClassMethods module" do
      rbs = generated_rbs(<<~RUBY)
        module Greetable
          extend ActiveSupport::Concern

          class_methods do
            def banner
              "hi"
            end
          end

          def greet
            "hello"
          end
        end
      RUBY

      greetable = parse_decls(rbs).find do |d|
        d.is_a?(RBS::AST::Declarations::Module) && d.name.to_s == "Greetable"
      end
      expect(greetable).not_to be_nil

      class_methods = greetable.members.find do |m|
        m.is_a?(RBS::AST::Declarations::Module) && m.name.to_s == "ClassMethods"
      end
      expect(class_methods).not_to be_nil, "expected a nested `module ClassMethods` in:\n#{rbs}"

      class_method_names = class_methods.members
        .grep(RBS::AST::Members::MethodDefinition).map { |m| m.name.to_s }
      expect(class_method_names).to include("banner")

      # `greet` is a direct instance method of the concern, NOT inside ClassMethods.
      direct_method_names = greetable.members
        .grep(RBS::AST::Members::MethodDefinition).map { |m| m.name.to_s }
      expect(direct_method_names).to include("greet")
      expect(class_method_names).not_to include("greet")
    end
  end
end
