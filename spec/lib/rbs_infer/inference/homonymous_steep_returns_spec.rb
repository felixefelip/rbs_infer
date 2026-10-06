# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# Steep's answer for each method's body was keyed by the method's NAME, per
# file. Two classes in one file defining `name` wrote one entry, and a method
# that read Steep's answer read whichever was written last. The wrong type then
# stood as that method's own declaration on the next run.
RSpec.describe "two classes in one file defining the same method" do
  around do |ex|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { ex.run } }
  end
  before { RbsInfer::Signatures::RbsTypeLookup.reset! }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def generate(target)
    RbsInfer::Analyzer.new(target_file: target, source_files: Dir["app/*.rb"]).generate_rbs
  end

  # Both bodies read through a local, which leaves them to Steep's answer.
  # `&.` is `T | nil` to Steep, so the two answers differ.
  def account = <<~RUBY
    class Account
      def name
        u = user
        u.name
      end
    end
  RUBY

  def order = <<~RUBY
    class Order
      def name
        _ = buyer
        _&.name
      end
    end
  RUBY

  before do
    write("app/person.rb", "class Person\n  def name = \"Ana\"\nend\n")
    write("sig/generated/person.rbs", "class Person\n  def name: () -> \"Ana\"\nend\n")
    write("sig/generated/forwards.rbs", "class Account\n  def user: () -> Person\nend\nclass Order\n  def buyer: () -> Person\nend\n")
  end

  it "types each from its own body" do
    rbs = generate(write("app/forwards.rb", "#{account}\n#{order}"))

    expect(rbs).to include(%(class Account\n  def name: () -> "Ana"\nend))
    expect(rbs).to include(%(class Order\n  def name: () -> "Ana"?\nend))
  end

  it "whichever is written first" do
    rbs = generate(write("app/forwards.rb", "#{order}\n#{account}"))

    expect(rbs).to include(%(class Account\n  def name: () -> "Ana"\nend))
    expect(rbs).to include(%(class Order\n  def name: () -> "Ana"?\nend))
  end
end
