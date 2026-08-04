require "spec_helper"
require "rbs_infer"
require "tmpdir"

RSpec.describe RbsInfer::Project::Corpus do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      described_class.reset!
      example.run
      described_class.reset!
    end
  end

  def write_file(name, content)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  # The point of the class: a second target must not rebuild what the first
  # already built, because none of it can see the target.
  it "hands the same indexes to every caller asking about the same files" do
    files = [write_file("card.rb", "class Card\n  include Eventable\nend\n"),
             write_file("eventable.rb", "module Eventable\nend\n")]

    first = described_class.for(files)
    second = described_class.for(files)

    expect(second).to equal(first)
    expect(second.parse_cache).to equal(first.parse_cache)
    expect(second.source_index).to equal(first.source_index)
    expect(second.file_index).to equal(first.file_index)
    expect(second.caller_file_cache).to equal(first.caller_file_cache)
    expect(second.mixin_index).to equal(first.mixin_index)
  end

  # A caller that rebuilt an equal list — the Ruby API does not have to hand
  # back the identical array the way the CLI does.
  it "answers the same corpus for an equal list built separately" do
    files = [write_file("card.rb", "class Card\nend\n")]

    expect(described_class.for(files.dup)).to equal(described_class.for(files))
  end

  it "builds a new corpus for a different list" do
    one = [write_file("card.rb", "class Card\nend\n")]
    two = [write_file("user.rb", "class User\nend\n")]

    expect(described_class.for(two)).not_to equal(described_class.for(one))
  end

  # The corpus outlives a single analysis, so a process that changes the files
  # under it needs a way out. The CLI never does — it reads `.rb` and writes
  # `.rbs` — but a long-lived host would.
  it "rebuilds after reset!" do
    files = [write_file("card.rb", "class Card\nend\n")]

    first = described_class.for(files)
    described_class.reset!

    expect(described_class.for(files)).not_to equal(first)
  end

  it "shares one parse cache with the mixin index it builds" do
    files = [write_file("card.rb", "class Card\n  include Eventable\nend\n"),
             write_file("eventable.rb", "module Eventable\nend\n")]

    corpus = described_class.for(files)
    corpus.mixin_index

    # The mixin walk parses every file; a shared cache means the corpus's own
    # cache is warm afterwards rather than each holding its own copy.
    expect(corpus.parse_cache.get(files.first)).not_to be_nil
    expect(corpus.mixin_index.hosts_of("Eventable")).to contain_exactly("Card")
  end
end
