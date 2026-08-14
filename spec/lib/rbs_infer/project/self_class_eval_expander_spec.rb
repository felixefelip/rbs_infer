# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Project::SelfClassEvalExpander do
  def expand(source) = described_class.expand(source)

  it "reopens the class the instance method is defined in" do
    expanded = expand(<<~RUBY)
      class Foo
        def build
          self.class.class_eval do
            def age
              25
            end
          end
        end
      end
    RUBY

    expect(expanded).to include("class Foo\n  def age\n    25\n  end\nend")
    expect(Prism.parse(expanded).success?).to be(true)
  end

  it "qualifies the target by its enclosing declarations" do
    expanded = expand(<<~RUBY)
      module Wrap
        class Foo
          def build
            self.class.class_eval { def age; 25; end }
          end
        end
      end
    RUBY

    expect(expanded).to include("class Wrap::Foo\n")
  end

  it "reopens a module target as a module" do
    expanded = expand(<<~RUBY)
      module Foo
        def build
          self.class.module_eval { def age; 25; end }
        end
      end
    RUBY

    expect(expanded).to include("module Foo\n")
  end

  # Each of these is a receiver or a `self` the call shape does not decide.
  describe "declines" do
    it "a singleton method, where `self.class` is `Class`" do
      expect(expand(<<~RUBY)).to be_nil
        class Foo
          def self.build
            self.class.class_eval { def age; 25; end }
          end
        end
      RUBY
    end

    it "a method inside `class << self`, for the same reason" do
      expect(expand(<<~RUBY)).to be_nil
        class Foo
          class << self
            def build
              self.class.class_eval { def age; 25; end }
            end
          end
        end
      RUBY
    end

    it "a receiver that is not `self.class`" do
      expect(expand(<<~RUBY)).to be_nil
        class Foo
          def build
            other.class.class_eval { def age; 25; end }
          end
        end
      RUBY
    end

    it "a bare `self`, whose singleton is the other half" do
      expect(expand(<<~RUBY)).to be_nil
        class Foo
          def build
            self.instance_eval { def age; 25; end }
          end
        end
      RUBY
    end

    it "the string form, whose body is not source this can read" do
      expect(expand(<<~RUBY)).to be_nil
        class Foo
          def build
            self.class.class_eval "def age; 25; end"
          end
        end
      RUBY
    end

    # `self` inside an arbitrary block is whatever yielded rebound it to, so the
    # enclosing declaration no longer says what `self.class` is — the same
    # reasoning that stopped block defs being attributed to their lexical owner.
    it "a method reached through a block" do
      expect(expand(<<~RUBY)).to be_nil
        class Foo
          configure do
            def build
              self.class.class_eval { def age; 25; end }
            end
          end
        end
      RUBY
    end

    it "a call nested in a block inside the method" do
      expect(expand(<<~RUBY)).to be_nil
        class Foo
          def build
            [1].each { self.class.class_eval { def age; 25; end } }
          end
        end
      RUBY
    end

    it "a call outside any class" do
      expect(expand("def build\n  self.class.class_eval { def age; 25; end }\nend\n")).to be_nil
    end

    it "a source with no eval at all, without parsing it" do
      expect(Prism).not_to receive(:parse)
      expect(expand("class Foo; end\n")).to be_nil
    end
  end

  it "is registered on the SourceExpanders seam" do
    expect(RbsInfer::Project::SourceExpanders.expanders).to include(described_class)
  end
end
