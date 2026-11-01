# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::NewCallCollector::ValueTypes do
  def value_types(local_var_types: {}, local_var_read_types: {}, expression_types: {})
    scope = RbsInfer::Inference::NewCallCollector::Scope.new(local_var_types: local_var_types, caller_class_name: nil)
    described_class.new(
      scope: scope, method_return_types: {}, owned_method_return_types: {}, local_var_read_types: local_var_read_types,
      method_type_resolver: nil, constant_arg_resolver: nil, self_types_by_method: {},
      module_self_types: {}, invoker_self_types: nil, inherited_selves: {}, expression_types: expression_types
    )
  end

  def read_of(source, name)
    found = nil
    walk = lambda do |node|
      found ||= node if node.is_a?(Prism::LocalVariableReadNode) && node.name.to_s == name
      node.compact_child_nodes.each { |child| walk.call(child) }
    end
    walk.call(Prism.parse(source).value)
    found
  end

  def position(read)
    [read.location.start_line, read.location.start_character_column]
  end

  describe "#receiver_type of a local" do
    it "is the type Steep gave the read, for a block parameter outside any def" do
      read = read_of(<<~'RUBY', "inflect")
        module Inflector
          configure do |inflect|
            inflect.singular(/s\z/, "")
          end
        end
      RUBY

      expect(value_types(local_var_read_types: { position(read) => "Rules" }).receiver_type(read)).to eq("Rules")
    end

    it "is the narrowed type of the read over the one the method's map holds" do
      read = read_of("session = find\nsession.touch if session\n", "session")
      types = value_types(local_var_types: { "session" => "Session?" },
                          local_var_read_types: { position(read) => "Session" })

      expect(types.receiver_type(read)).to eq("Session")
    end

    it "falls back to the method's map where the read has no type" do
      read = read_of("session = find\nsession.touch\n", "session")

      expect(value_types(local_var_types: { "session" => "Session" }).receiver_type(read)).to eq("Session")
    end
  end

  describe "#receiver_type of a call made on a receiver" do
    def class_call(source)
      Prism.parse(source).value.statements.body.first.receiver
    end

    it "is the type Steep gave the call" do
      call = class_call("self.class.lookup(:wheel)\n")
      key = RbsInfer::Signatures::SteepBridge.prism_expression_key(call.location)

      expect(value_types(expression_types: { key => "singleton(::Car)" }).receiver_type(call)).to eq("singleton(::Car)")
    end
  end
end
