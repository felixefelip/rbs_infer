# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/support"
require_relative "../../.rubocop/class_length_ceiling"

RSpec.describe RuboCop::Cop::Project::ClassLengthCeiling, :config do
  let(:cop_config) { { "Max" => 3, "CountAsOne" => [], "Ceilings" => { "lib/big.rb" => 5 } } }

  def class_of(lines)
    "class Big\n#{(1..lines).map { |i| "  a#{i} = #{i}\n" }.join}end\n"
  end

  it "holds an unlisted file to Max" do
    expect_offense(<<~RUBY, "lib/other.rb")
      class Other
      ^^^^^^^^^^^ Class has too many lines. [4/3]
        a = 1
        b = 2
        c = 3
        d = 4
      end
    RUBY
  end

  it "lets a listed file's largest class sit at its ceiling" do
    expect_no_offenses(class_of(5), "lib/big.rb")
  end

  it "flags a listed class that grew past its ceiling" do
    expect_offense(<<~RUBY, "lib/big.rb")
      class Big
      ^^^^^^^^^ Class has too many lines. [6/5]
        a = 1
        b = 2
        c = 3
        d = 4
        e = 5
        f = 6
      end
    RUBY
  end

  it "asks for the ceiling to come down when the class shrank" do
    expect_offense(<<~RUBY, "lib/big.rb")
      class Big
      ^^^^^^^^^ Largest class shrank to 4 lines; lower this file's ceiling in .rubocop.yml from 5.
        a = 1
        b = 2
        c = 3
        d = 4
      end
    RUBY
  end

  it "asks for the ceiling to go when the class is back under Max" do
    expect_offense(<<~RUBY, "lib/big.rb")
      class Big
      ^^^^^^^^^ No class here is over 3 lines any more; remove this file's ceiling from .rubocop.yml.
        a = 1
      end
    RUBY
  end

  it "judges a stale ceiling by the file's largest class, not a smaller one beside it" do
    expect_no_offenses(<<~RUBY, "lib/big.rb")
      class Small
        a = 1
      end

      #{class_of(5)}
    RUBY
  end
end
