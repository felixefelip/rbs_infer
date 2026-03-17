require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::SteepBridge, :dummy_app do
  subject(:bridge) { described_class.new }

  describe "#local_var_types_per_method" do
    it "resolves constant receiver method calls" do
      code = <<~RUBY
        class Foo
          def bar
            comment = Comment.find(1)
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["comment"]).to eq("Comment")
    end

    it "resolves chained method calls" do
      code = <<~RUBY
        class Foo
          def bar
            user = User.where(active: true).first
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["user"]).to eq("User?")
    end

    it "resolves comparison operators to bool" do
      code = <<~RUBY
        class Foo
          def bar
            result = 42 > 10
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["result"]).to eq("bool")
    end

    it "separates variables by method" do
      code = <<~RUBY
        class Foo
          def bar
            x = Comment.find(1)
          end

          def baz
            y = 42
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]["x"]).to eq("Comment")
      expect(result["baz"]["y"]).to eq("Integer")
      expect(result["bar"]).not_to have_key("y")
    end

    it "skips untyped and nil assignments" do
      code = <<~RUBY
        class Foo
          def bar
            x = nil
          end
        end
      RUBY

      result = bridge.local_var_types_per_method(code)
      expect(result["bar"]).not_to have_key("x")
    end

    it "returns empty hash for unparseable code" do
      result = bridge.local_var_types_per_method("!!!invalid ruby")
      expect(result).to eq({})
    end
  end

  describe "#method_return_types" do
    it "resolves method return types from body expressions" do
      code = <<~RUBY
        class Foo
          def bar
            42 > 10
          end
        end
      RUBY

      result = bridge.method_return_types(code)
      expect(result["bar"]).to eq("bool")
    end

    it "resolves chained method return types" do
      code = <<~RUBY
        class Foo
          def bar
            User.where(active: true).first
          end
        end
      RUBY

      result = bridge.method_return_types(code)
      expect(result["bar"]).to eq("User?")
    end

    it "excludes empty methods" do
      code = <<~RUBY
        class Foo
          def bar
          end
        end
      RUBY

      result = bridge.method_return_types(code)
      expect(result).not_to have_key("bar")
    end

    it "returns empty hash for unparseable code" do
      result = bridge.method_return_types("!!!invalid ruby")
      expect(result).to eq({})
    end
  end

  describe "#all_expression_types" do
    it "maps line:column to type for all typed expressions" do
      code = <<~RUBY
        class Foo
          def bar
            x = Comment.find(1)
          end
        end
      RUBY

      result = bridge.all_expression_types(code)
      expect(result).not_to be_empty
      # The lvasgn for x is on line 3
      typed_values = result.values
      expect(typed_values).to include("Comment")
    end

    it "returns empty hash for unparseable code" do
      result = bridge.all_expression_types("!!!invalid ruby")
      expect(result).to eq({})
    end
  end
end
