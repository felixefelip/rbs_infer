# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::InheritedForwards do
  # The syntactic half: which `def self.` bodies hand their whole argument list
  # to a method of a fresh instance. Whether a given target INHERITS one of them
  # is the other half, proved off the RBS environment and covered by the
  # example65 integration snapshots.
  describe ".transparent_forwards" do
    def forwards(source, method_name = "handle")
      described_class.transparent_forwards(Prism.parse(source).value, method_name)
    end

    it "finds the forward through a local holding a fresh instance" do
      source = <<~RUBY
        class Dispatcher
          def self.dispatch(*args, **kwargs)
            handler = new
            handler.handle(*args, **kwargs)
            handler
          end
        end
      RUBY

      expect(forwards(source)).to eq(["dispatch"])
    end

    it "finds it called straight on `new`, and on `self.new`" do
      expect(forwards(<<~RUBY)).to eq(["dispatch"])
        class Dispatcher
          def self.dispatch(*args, **kwargs) = new.handle(*args, **kwargs)
        end
      RUBY

      expect(forwards(<<~RUBY)).to eq(["dispatch"])
        class Dispatcher
          def self.dispatch(*args, **kwargs) = self.new.handle(*args, **kwargs)
        end
      RUBY
    end

    it "finds a rest-only forward" do
      expect(forwards(<<~RUBY)).to eq(["dispatch"])
        class Dispatcher
          def self.dispatch(*args) = new.handle(*args)
        end
      RUBY
    end

    # The receiver has to be an instance of the class the CALL SITE named, which
    # is what `new` is inside an inherited singleton method. `Other.new` is a
    # fixed class and carries none of it.
    it "declines when the receiver is another class's instance" do
      expect(forwards(<<~RUBY)).to be_empty
        class Dispatcher
          def self.dispatch(*args, **kwargs) = Other.new.handle(*args, **kwargs)
        end
      RUBY
    end

    # Transparency is the whole licence for mapping the caller's arguments onto
    # the handler's parameters position for position. Anything that disturbs the
    # correspondence answers nothing rather than guessing.
    it "declines when the arguments are not exactly the splatted rest and keyrest" do
      expect(forwards(<<~RUBY)).to be_empty                     # an argument added
        class Dispatcher
          def self.dispatch(*args, **kwargs) = new.handle(:extra, *args, **kwargs)
        end
      RUBY

      expect(forwards(<<~RUBY)).to be_empty                     # keyrest dropped
        class Dispatcher
          def self.dispatch(*args, **kwargs) = new.handle(*args)
        end
      RUBY

      expect(forwards(<<~RUBY)).to be_empty                     # read, not splatted
        class Dispatcher
          def self.dispatch(*args, **kwargs) = new.handle(args, kwargs)
        end
      RUBY

      expect(forwards(<<~RUBY)).to be_empty                     # a different local
        class Dispatcher
          def self.dispatch(*args, **kwargs)
            other = [1]
            new.handle(*other, **kwargs)
          end
        end
      RUBY
    end

    it "declines a method with no rest or keyrest to forward" do
      expect(forwards(<<~RUBY)).to be_empty
        class Dispatcher
          def self.dispatch(one, two) = new.handle(one, two)
        end
      RUBY
    end

    it "declines an INSTANCE method, which no call site reaches by class name" do
      expect(forwards(<<~RUBY)).to be_empty
        class Dispatcher
          def dispatch(*args, **kwargs) = new.handle(*args, **kwargs)
        end
      RUBY
    end

    it "answers only about the method asked for" do
      source = <<~RUBY
        class Dispatcher
          def self.dispatch(*args, **kwargs) = new.handle(*args, **kwargs)
        end
      RUBY

      expect(forwards(source, "other")).to be_empty
    end

    it "finds every forward in the file" do
      source = <<~RUBY
        class Dispatcher
          def self.dispatch(*args, **kwargs) = new.handle(*args, **kwargs)
          def self.dispatch_now(*args, **kwargs) = new.handle(*args, **kwargs)
        end
      RUBY

      expect(forwards(source)).to contain_exactly("dispatch", "dispatch_now")
    end
  end
end
