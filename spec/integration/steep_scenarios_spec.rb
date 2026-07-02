# frozen_string_literal: true

require "spec_helper"
require_relative "../support/steep_scenario_helper"

# End-to-end scenarios for the nilable-attr / precondition-contract pipeline:
# plain Ruby -> rbs_infer generates the RBS (e.g. `attr_accessor board:
# Board?` from the external setter) -> `steep check` infers, enforces and
# type-checks. Each example is an isolated temp project (see
# SteepScenarioHelper), so `Column`/`Board` are reused without conflict.
#
# The full generated RBS is asserted inline (the `expected_rbs` heredoc) so the
# whole generator output is verified in-place; the `diagnostics` assertions
# capture the Steep behavior.
#
# Slow (rbs_infer + steep per example); kept in spec/integration.
RSpec.describe "rbs_infer -> Steep precondition scenarios" do
  include SteepScenarioHelper

  # Column#board is inferred `Board?` (set only from outside), and
  # `set_default_user_name` reads it — the shape the whole nilable-attr work
  # is about. `save` calls `set_default_user_name` via self.
  MODELS = <<~RUBY
    class Column
      attr_accessor :board, :user_name

      def initialize(name:)
        @name = name
      end

      def set_default_user_name
        self.user_name = board.user_name
      end

      def save
        set_default_user_name
        true
      end
    end

    class Board
      attr_reader :user_name

      def initialize(user_name:)
        @user_name = user_name
      end
    end
  RUBY

  # Direct explicit-receiver call (no `save` layer): the model deliberately
  # omits `save` — a method that calls `set_default_user_name` without
  # establishing board would (correctly) keep it unenforced. See the
  # transitive example below for the `save` chain.
  DIRECT_MODEL = <<~RUBY
    class Column
      attr_accessor :board, :user_name

      def initialize(name:)
        @name = name
      end

      def set_default_user_name
        self.user_name = board.user_name
      end
    end

    class Board
      attr_reader :user_name

      def initialize(user_name:)
        @user_name = user_name
      end
    end
  RUBY

  it "generates a nilable `board` and narrows a direct explicit-receiver call" do
    result = steep_scenario(DIRECT_MODEL + <<~RUBY)
      class Runner
        def self.run
          column = Column.new(name: "To Do")
          column.board = Board.new(user_name: "Jo")
          column.set_default_user_name
        end
      end
    RUBY

    expected_rbs = <<~RBS
      class Column
        @name: String
        attr_accessor board: Board?
        attr_accessor user_name: String
        def initialize: (name: String) -> void
        def set_default_user_name: () -> String
      end

      class Board
        attr_reader user_name: String
        def initialize: (user_name: String) -> void
      end

      class Runner
        def self.run: () -> String
      end
    RBS

    expect(result.generated_rbs.chomp).to eq(expected_rbs.chomp)
    expect(result.diagnostics).to be_empty
  end

  it "resolves the transitive chain (save -> set_default_user_name) when the caller sets board" do
    result = steep_scenario(MODELS + <<~RUBY)
      class Runner
        def self.run
          column = Column.new(name: "To Do")
          column.board = Board.new(user_name: "Jo")
          column.save
        end
      end
    RUBY

    expected_rbs = <<~RBS
      class Column
        @name: String
        attr_accessor board: Board?
        attr_accessor user_name: String
        def initialize: (name: String) -> void
        def set_default_user_name: () -> String
        def save: () -> bool
      end

      class Board
        attr_reader user_name: String
        def initialize: (user_name: String) -> void
      end

      class Runner
        def self.run: () -> bool
      end
    RBS

    expect(result.generated_rbs.chomp).to eq(expected_rbs.chomp)
    expect(result.diagnostics).to be_empty
  end

  it "flags the caller that reaches save without establishing board" do
    result = steep_scenario(MODELS + <<~RUBY)
      class Runner
        def self.run_safe
          c = Column.new(name: "To Do")
          c.board = Board.new(user_name: "Jo")
          c.save
        end

        def self.run_unsafe
          c = Column.new(name: "To Do")
          c.save
        end
      end
    RUBY

    expected_rbs = <<~RBS
      class Column
        @name: String
        attr_accessor board: Board?
        attr_accessor user_name: String
        def initialize: (name: String) -> void
        def set_default_user_name: () -> String
        def save: () -> bool
      end

      class Board
        attr_reader user_name: String
        def initialize: (user_name: String) -> void
      end

      class Runner
        def self.run_safe: () -> bool
        def self.run_unsafe: () -> bool
      end
    RBS

    expect(result.generated_rbs.chomp).to eq(expected_rbs.chomp)
    # The requirement bubbles up: the unsafe `c.save` is flagged, and the chain
    # stays unenforced so the body error surfaces too.
    expect(result.diagnostics).to include(a_string_matching(/`save` requires `self\.board`/))
    expect(result.diagnostics).to include(a_string_matching(/\(::Board \| nil\)` does not have method `user_name`/))
  end

  # --- Documented known gaps (felixefelip/steep#53) ---------------------------

  it "is a FALSE POSITIVE when board is set inside a factory (fact crosses no return boundary)" do
    result = steep_scenario(MODELS + <<~RUBY)
      class Factory
        def self.build
          c = Column.new(name: "To Do")
          c.board = Board.new(user_name: "Jo")
          c
        end

        def self.run
          column = build      # board is set, but the return type is just Column
          column.save
        end
      end
    RUBY

    expected_rbs = <<~RBS
      class Column
        @name: String
        attr_accessor board: Board?
        attr_accessor user_name: String
        def initialize: (name: String) -> void
        def set_default_user_name: () -> String
        def save: () -> bool
      end

      class Board
        attr_reader user_name: String
        def initialize: (user_name: String) -> void
      end

      class Factory
        def self.build: () -> Column
        def self.run: () -> bool
      end
    RBS

    expect(result.generated_rbs.chomp).to eq(expected_rbs.chomp)
    # Runtime is safe; Steep still errors because "board is set" doesn't cross
    # the method-return boundary (issue #53, F1). Locks the current behavior.
    expect(result.diagnostics).to include(a_string_matching(/`save` requires `self\.board`/))
  end

  it "is UNSOUND under aliasing (Steep passes though runtime would raise)" do
    # Minimal model without the contract methods, to isolate the aliasing hole:
    # `b` aliases `a`, so `b.board = nil` nils `a.board` at runtime, but Steep
    # tracks `a.board` and `b.board` as separate pure nodes (issue #53, U1).
    result = steep_scenario(<<~RUBY)
      class Board
        attr_reader :user_name
        def initialize(user_name:)
          @user_name = user_name
        end
      end

      class Column
        attr_accessor :board
        def initialize; end
      end

      class Runner
        def self.run
          a = Column.new
          b = a
          a.board = Board.new(user_name: "Jo")
          b.board = nil            # same object as `a`
          a.board.user_name        # runtime: NoMethodError
        end

        def self.setup
          c = Column.new
          c.board = Board.new(user_name: "Jo")  # makes rbs_infer type board as Board?
        end
      end
    RUBY

    # Note the `(Board | nil)?` — rbs_infer doesn't normalize `(T | nil)?` to
    # `T?`; the inline snapshot pins that faithfully.
    expected_rbs = <<~RBS
      class Board
        attr_reader user_name: String
        def initialize: (user_name: String) -> void
      end

      class Column
        attr_accessor board: (Board | nil)?
        def initialize: () -> untyped
      end

      class Runner
        def self.run: () -> String
        def self.setup: () -> Board
      end
    RBS

    expect(result.generated_rbs.chomp).to eq(expected_rbs.chomp)
    expect(result.diagnostics).to be_empty # <- documents the unsoundness
  end
end
