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

    # The rule is about the whole `def`, not the call node. A dispatcher that
    # keeps an argument of its own shifts every remaining one by a position, so
    # the handler's first parameter would be typed from the caller's control
    # argument — a wrong type, not a missing one.
    it "declines a dispatcher that keeps parameters of its own" do
      expect(forwards(<<~RUBY)).to be_empty                     # leading required
        class Dispatcher
          def self.dispatch(tag, *args, **kwargs) = new.handle(*args, **kwargs)
        end
      RUBY

      expect(forwards(<<~RUBY)).to be_empty                     # optional
        class Dispatcher
          def self.dispatch(tag = nil, *args, **kwargs) = new.handle(*args, **kwargs)
        end
      RUBY

      expect(forwards(<<~RUBY)).to be_empty                     # named keyword
        class Dispatcher
          def self.dispatch(*args, tag: nil, **kwargs) = new.handle(*args, **kwargs)
        end
      RUBY
    end

    it "allows a block parameter, which occupies no argument position" do
      expect(forwards(<<~RUBY)).to eq(["dispatch"])
        class Dispatcher
          def self.dispatch(*args, **kwargs, &block) = new.handle(*args, **kwargs)
        end
      RUBY
    end

    # The splat can read faithful at the call while the values have already
    # moved. This is how a real dispatcher peels off its own control argument.
    it "declines when the forwarded values are touched before the call" do
      expect(forwards(<<~RUBY)).to be_empty                     # reassigned
        class Dispatcher
          def self.dispatch(*args, **kwargs)
            args = args.drop(1)
            new.handle(*args, **kwargs)
          end
        end
      RUBY

      expect(forwards(<<~RUBY)).to be_empty                     # mutated in place
        class Dispatcher
          def self.dispatch(*args, **kwargs)
            args.shift
            new.handle(*args, **kwargs)
          end
        end
      RUBY

      expect(forwards(<<~RUBY)).to be_empty                     # keyrest mutated
        class Dispatcher
          def self.dispatch(*args, **kwargs)
            kwargs.delete(:tag)
            new.handle(*args, **kwargs)
          end
        end
      RUBY
    end

    # Splatting hands over the elements, never the collection, so a second
    # forward cannot disturb the first. The full template method needs this.
    it "allows the same arguments to reach two handlers" do
      source = <<~RUBY
        class Dispatcher
          def self.run(*args, **kwargs)
            h = new
            h.setup(*args, **kwargs)
            h.handle(*args, **kwargs)
            h
          end
        end
      RUBY

      expect(forwards(source, "handle")).to eq(["run"])
      expect(forwards(source, "setup")).to eq(["run"])
    end

    it "finds the `class << self` spelling" do
      expect(forwards(<<~RUBY)).to eq(["dispatch"])
        class Dispatcher
          class << self
            def dispatch(*args, **kwargs) = new.handle(*args, **kwargs)
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

    # The walk has no order, so a local reassigned later would otherwise stay
    # marked as holding a fresh instance for the rest of the body.
    it "declines a local that is not always a fresh instance" do
      expect(forwards(<<~RUBY)).to be_empty
        class Dispatcher
          def self.dispatch(*args, **kwargs)
            handler = new
            handler = Other.build
            handler.handle(*args, **kwargs)
          end
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

  describe "#for_methods" do
    # One dispatcher can drive several handlers, and keeping a single name would
    # leave the rest `untyped` with nothing saying why.
    it "keeps every method a forward reaches, not the last one seen" do
      index = described_class.new(
        target_class: "Whatever",
        source_index: RbsInfer::Project::SourceIndex.new([]),
        parse_cache: RbsInfer::Project::ParseCache.new
      )
      allow(index).to receive(:forwards_into).with("setup").and_return(["run"])
      allow(index).to receive(:forwards_into).with("handle").and_return(["run"])

      expect(index.for_methods(["setup", "handle"])).to eq("run" => ["setup", "handle"])
    end

    it "answers nothing when asked about nothing" do
      index = described_class.new(
        target_class: "Whatever",
        source_index: RbsInfer::Project::SourceIndex.new([]),
        parse_cache: RbsInfer::Project::ParseCache.new
      )

      expect(index.for_methods([])).to eq({})
    end
  end
end
