# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "tmpdir"
require "fileutils"

# `_` is an ordinary local. Steep's upstream reads `_ = expr` as a cast —
# `untyped`, whatever `expr` is — and that is a convention of the checker,
# not of Ruby: ActiveSupport writes `_ = #{receiver}` in what `delegate`
# generates to evaluate the receiver once. The fork keeps the cast only for a
# target that asks for it (`underscore_casts!`), and the analyzer reads code
# as Ruby, so a method that reads through `_` is typed by what `_` holds.
RSpec.describe "a method that reads through `_`" do
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
    RbsInfer::Analyzer.new(
      target_class: "Target", target_file: target, source_files: Dir["app/*.rb"]
    ).generate_rbs
  end

  before do
    write("app/user.rb", "class User\n  def full_name(title)\n    title\n  end\nend\n")
    write("sig/generated/user.rbs", "class User\n  def full_name: (String title) -> String\nend\n")
    write("sig/generated/target.rbs", "class Target\n  def user: () -> User\nend\n")
  end

  it "is typed by what `_` holds" do
    target = write("app/target.rb", <<~RUBY)
      class Target
        def user = User.new

        def user_full_name
          _ = user
          _.full_name("Dr")
        end
      end
    RUBY

    expect(generate(target)).to include("def user_full_name: () -> String")
  end
end
