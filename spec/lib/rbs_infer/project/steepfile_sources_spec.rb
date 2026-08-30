require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Project::SteepfileSources do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write(relative_path, content)
    path = File.join(@dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def sources = described_class.call(dir: @dir)

  it "returns nil when the project has no Steepfile" do
    write("app/models/user.rb", "class User; end\n")

    expect(sources).to be_nil
  end

  it "reads the `check` patterns" do
    write("Steepfile", <<~RUBY)
      target :app do
        check "src"
        signature "sig"
      end
    RUBY
    write("src/user.rb", "class User; end\n")
    write("elsewhere/other.rb", "class Other; end\n")

    expect(sources).to contain_exactly("src/user.rb")
  end

  # The whole point of reading the Steepfile: a project that keeps its code
  # somewhere the Rails layout never mentions is served without the CLI
  # knowing anything about that project's shape.
  it "reads a directory the default layout would never glob" do
    write("Steepfile", <<~RUBY)
      target :app do
        check "packages/billing/lib"
        signature "sig"
      end
    RUBY
    write("packages/billing/lib/invoice.rb", "class Invoice; end\n")

    expect(sources).to eq(["packages/billing/lib/invoice.rb"])
  end

  # A Steepfile `ignore` says "report no diagnostics here", not "this file is
  # not part of the program". Asking what to CHECK honors it; asking what the
  # program DECLARES — which is what a resolution corpus asks — does not.
  describe "`ignore`" do
    before do
      write("Steepfile", <<~RUBY)
        target :app do
          check "app"
          ignore "app/generated"
          signature "sig"
        end
      RUBY
      write("app/user.rb", "class User; end\n")
      write("app/generated/thing.rb", "class Thing; end\n")
    end

    it "is honored when asking what to check" do
      expect(described_class.call(dir: @dir, ignores: true)).to contain_exactly("app/user.rb")
    end

    it "is not honored when asking what the program declares" do
      expect(described_class.call(dir: @dir, ignores: false))
        .to contain_exactly("app/user.rb", "app/generated/thing.rb")
    end
  end

  # `.rbs` is not Ruby, and this list is handed to a Ruby parser. Inline RBS
  # is, so it stays.
  it "reads inline sources but never signatures" do
    write("Steepfile", <<~RUBY)
      target :app do
        check "app"
        check "inline", inline: true
        signature "sig"
      end
    RUBY
    write("app/user.rb", "class User; end\n")
    write("inline/post.rb", "class Post; end\n")
    write("sig/user.rbs", "class User\nend\n")

    expect(sources).to contain_exactly("app/user.rb", "inline/post.rb")
  end

  it "reads every target, and the groups inside one" do
    write("Steepfile", <<~RUBY)
      target :app do
        check "app"
        signature "sig"

        group :admin do
          check "admin"
        end
      end

      target :tools do
        check "tools"
        signature "sig"
      end
    RUBY
    write("app/user.rb", "class User; end\n")
    write("admin/panel.rb", "class Panel; end\n")
    write("tools/build.rb", "class Build; end\n")

    expect(sources).to contain_exactly("app/user.rb", "admin/panel.rb", "tools/build.rb")
  end

  # Silently falling through would degrade every type in the run to `untyped`
  # with nothing said about why.
  it "warns and falls back when the Steepfile cannot be read" do
    write("Steepfile", "target :app do\n  check\n")

    expect { expect(sources).to be_nil }.to output(/could not be read/).to_stderr
  end

  it "warns and falls back when nothing matched" do
    write("Steepfile", <<~RUBY)
      target :app do
        check "nowhere"
        signature "sig"
      end
    RUBY

    expect { expect(sources).to be_nil }.to output(/no source files matched/).to_stderr
  end
end
