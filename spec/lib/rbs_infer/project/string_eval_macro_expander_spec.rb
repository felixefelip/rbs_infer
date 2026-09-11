# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/project/string_eval_macro_expander"

RSpec.describe RbsInfer::Project::StringEvalMacroExpander do
  # A hand-built index, so the expander is exercised without a corpus on disk.
  # The real one (`StringEvalMacroIndex`) is what refuses an ambiguous name.
  def index_for(macro_source)
    macros = RbsInfer::Project::StringEvalMacro
             .macros_in(Prism.parse(macro_source).value)
             .to_h { |macro| [macro.name, macro] }

    Class.new do
      define_method(:any?) { !macros.empty? }
      define_method(:[]) { |name| macros[name] }
    end.new
  end

  def expand(macro_source, caller_source)
    described_class.expand(caller_source, macros: index_for(macro_source))
  end

  # The plainest form of the idiom, and the one every `attr_`-shaped macro in
  # the wild is written as.
  ACCESSOR_MACRO = <<~'RUBY'
    module Slots
      def slot(name)
        class_eval <<-CODE
          def #{name}
            @#{name}
          end

          def #{name}=(value)
            @#{name} = value
          end
        CODE
      end
    end
  RUBY

  it "renders the macro's string at the call site that supplies the name" do
    expanded = expand(ACCESSOR_MACRO, "class Widget\n  slot :size\nend\n")

    expect(expanded).to include("class Widget\n  def size\n    @size\n  end")
    expect(expanded).to include("def size=(value)\n    @size = value\n  end")
  end

  # The call is not desugared AWAY: it stays as evidence about the macro's own
  # parameters, which is how `slot`'s signature gets inferred at all.
  it "keeps the original call" do
    expanded = expand(ACCESSOR_MACRO, "class Widget\n  slot :size\nend\n")

    expect(expanded).to include("slot :size")
  end

  it "renders one reopen per call site in the same body" do
    expanded = expand(ACCESSOR_MACRO, "class Widget\n  slot :size\n  slot :colour\nend\n")

    expect(expanded).to include("def size\n")
    expect(expanded).to include("def colour\n")
  end

  # Ruby interpolates a symbol and a string identically, which is why a macro
  # can take either.
  it "accepts a string argument as Ruby does" do
    expanded = expand(ACCESSOR_MACRO, "class Widget\n  slot \"size\"\nend\n")

    expect(expanded).to include("def size\n")
  end

  it "reopens the qualified name of a nested class" do
    expanded = expand(ACCESSOR_MACRO, "module Shop\n  class Widget\n    slot :size\n  end\nend\n")

    expect(expanded).to include("class Shop::Widget\n")
  end

  it "reopens a module as a module" do
    expanded = expand(ACCESSOR_MACRO, "module Sizing\n  slot :size\nend\n")

    expect(expanded).to include("module Sizing\n  def size")
  end

  it "does nothing when the body calls no macro" do
    expect(expand(ACCESSOR_MACRO, "class Widget\n  def size; 1; end\nend\n")).to be_nil
  end

  # A macro call inside a `def` runs when that method runs, against whatever
  # `self` is then — which this cannot name.
  it "ignores a call written inside a method" do
    expect(expand(ACCESSOR_MACRO, "class Widget\n  def build\n    slot :size\n  end\nend\n")).to be_nil
  end

  describe "a branch in the macro" do
    BRANCHED_MACRO = <<~'RUBY'
      module Slots
        def slot(name, writable: true)
          class_eval <<-CODE
            def #{name}
              @#{name}
            end
          CODE

          if writable
            class_eval <<-CODE
              def #{name}=(value)
                @#{name} = value
              end
            CODE
          end
        end
      end
    RUBY

    it "takes the definition's default when the call passes no keyword" do
      expanded = expand(BRANCHED_MACRO, "class Widget\n  slot :size\nend\n")

      expect(expanded).to include("def size=(value)")
    end

    it "follows the call site's keyword over the default" do
      expanded = expand(BRANCHED_MACRO, "class Widget\n  slot :size, writable: false\nend\n")

      expect(expanded).to include("def size\n")
      expect(expanded).not_to include("def size=")
    end
  end

  # The condition and the interpolation are one question, answered by one
  # folder. These four shapes are what that bought: each used to be DECIDED by
  # the reader that could not read it — an unknown predicate spelled `false`,
  # which is not a refusal but a vote for the `else` branch.
  describe "reading the condition" do
    def negated_macro
      <<~'RUBY'
        module Slots
          def slot(name, writable: true)
            if !writable
              class_eval "def #{name}_ro; end"
            else
              class_eval "def #{name}_rw; end"
            end
          end
        end
      RUBY
    end

    # Used to emit `size_rw` for BOTH call sites: `!writable` is not a bare
    # parameter read, so the old reader scored it `false` and took the `else`.
    it "reads a negated parameter" do
      expect(expand(negated_macro, "class Widget\n  slot :size\nend\n")).to include("def size_rw")
      expect(expand(negated_macro, "class Widget\n  slot :size, writable: false\nend\n"))
        .to include("def size_ro")
    end

    def case_macro
      <<~'RUBY'
        module Slots
          def slot(name, kind: :ro)
            case kind
            when :ro then class_eval "def #{name}; end"
            when :rw then class_eval "def #{name}=(v); end"
            else          class_eval "def #{name}_none; end"
            end
          end
        end
      RUBY
    end

    # A `case` used to be no condition at all — every branch was collected with
    # the guards of the statement around it, so all three were emitted.
    it "follows the branch a case selects" do
      expanded = expand(case_macro, "class Widget\n  slot :size, kind: :rw\nend\n")

      expect(expanded).to include("def size=(v)")
      expect(expanded).not_to include("def size;")
      expect(expanded).not_to include("def size_none")
    end

    it "takes a case's else when no when matches" do
      expect(expand(case_macro, "class Widget\n  slot :size, kind: :other\nend\n"))
        .to include("def size_none")
    end

    def short_circuit_macro
      <<~'RUBY'
        module Slots
          def slot(name, writable: false)
            class_eval "def #{name}; end"
            writable && class_eval("def #{name}=(v); end")
          end
        end
      RUBY
    end

    # `x && class_eval(…)` is a condition written without an `if`, and used to
    # be read as no condition — the writer was emitted whatever `writable` said.
    it "reads a short-circuit as the condition it is" do
      off = expand(short_circuit_macro, "class Widget\n  slot :size\nend\n")
      on = expand(short_circuit_macro, "class Widget\n  slot :size, writable: true\nend\n")

      expect(off).not_to include("def size=")
      expect(on).to include("def size=(v)")
    end
  end

  # Every uncertainty declines the WHOLE macro. Emitting the reader whose writer
  # was declined is not "less" — it is a class that silently has no `x=`.
  describe "declining" do
    it "declines an interpolation that is not a plain parameter read" do
      macro = <<~'RUBY'
        module Slots
          def slot(name)
            class_eval "def #{name.to_s.upcase}; end"
          end
        end
      RUBY

      expect(expand(macro, "class Widget\n  slot :size\nend\n")).to be_nil
    end

    it "declines an argument with no text to interpolate" do
      expanded = expand(ACCESSOR_MACRO, "class Widget\n  slot SOME_CONST\nend\n")

      expect(expanded).to be_nil
    end

    it "declines a splatted argument list" do
      expanded = expand(ACCESSOR_MACRO, "class Widget\n  slot(*names)\nend\n")

      expect(expanded).to be_nil
    end

    it "declines a branch it cannot decide from literals" do
      macro = <<~'RUBY'
        module Slots
          def slot(name, writable: CONFIGURED)
            if writable
              class_eval "def #{name}; end"
            end
          end
        end
      RUBY

      expect(expand(macro, "class Widget\n  slot :size\nend\n")).to be_nil
    end

    it "declines a call passing more positional arguments than the macro takes" do
      expanded = expand(ACCESSOR_MACRO, "class Widget\n  slot :size, :colour\nend\n")

      expect(expanded).to be_nil
    end

    # The shape that used to pick a branch instead of refusing: `fancy_mode?`
    # is not a parameter, so the old reader scored the predicate `false` and
    # emitted `size_plain` — a method the macro defines only when the condition
    # it could not read says so.
    it "declines a predicate it cannot read" do
      macro = <<~'RUBY'
        module Slots
          def slot(name)
            if fancy_mode?
              class_eval "def #{name}_fancy; end"
            else
              class_eval "def #{name}_plain; end"
            end
          end
        end
      RUBY

      expect(expand(macro, "class Widget\n  slot :size\nend\n")).to be_nil
    end

    # A `class_eval` under a shape the walk does not read at all. The body runs
    # twice here, and how many `def`s that makes is not the question — whether
    # the walk may treat "I did not read this" as "this runs" is.
    it "declines a class_eval reached through a block" do
      macro = <<~'RUBY'
        module Slots
          def slot(name)
            %w[a b].each do |suffix|
              class_eval "def #{name}; end"
            end
          end
        end
      RUBY

      expect(expand(macro, "class Widget\n  slot :size\nend\n")).to be_nil
    end

    # An unreadable chunk is collected under a barrier rather than skipped: it
    # has to poison the macro, not vanish and leave the readable chunks to
    # render a class with a reader and no writer.
    it "declines the whole macro for one unreadable chunk" do
      macro = <<~'RUBY'
        module Slots
          def slot(name)
            class_eval "def #{name}; end"
            [1].each { class_eval "def #{name}=(v); end" }
          end
        end
      RUBY

      expect(expand(macro, "class Widget\n  slot :size\nend\n")).to be_nil
    end
  end

  # A block-taking `class_eval` is `ClassEvalExpander`'s and
  # `StoredBlockReplayExpander`'s subject; reading it here too would rewrite the
  # same body twice.
  it "leaves a block-form class_eval alone" do
    macro = <<~RUBY
      module Slots
        def slot(name)
          class_eval do
            def size; end
          end
        end
      end
    RUBY

    expect(expand(macro, "class Widget\n  slot :size\nend\n")).to be_nil
  end
end
