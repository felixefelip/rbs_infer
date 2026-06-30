require "spec_helper"
require "rbs_infer"
require "tmpdir"

RSpec.describe RbsInfer::Project::MixinIndex do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write_file(name, content)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  it "alcança o host e os concerns irmãos do módulo-alvo" do
    eventable = write_file("eventable.rb", <<~RUBY)
      module Eventable
        def track_event(action) = nil
      end
    RUBY
    host = write_file("widget.rb", <<~RUBY)
      class Widget
        include Eventable
        include Widget::Publishable
        include Widget::Closeable
      end
    RUBY
    publishable = write_file("widget/publishable.rb", <<~RUBY)
      module Widget::Publishable
        def publish = track_event(:published)
      end
    RUBY
    closeable = write_file("widget/closeable.rb", <<~RUBY)
      module Widget::Closeable
        def close = track_event(:closed)
      end
    RUBY

    index = described_class.new([eventable, host, publishable, closeable])

    # host + ambos os irmãos (que nunca nomeiam Eventable)
    expect(index.files_reaching("Eventable"))
      .to contain_exactly(host, publishable, closeable)
  end

  it "resolve includes multi-linha e com namespace" do
    host = write_file("card.rb", <<~RUBY)
      class Card
        include Accessible, Eventable,
          Statuses
      end
    RUBY
    eventable = write_file("eventable.rb", "module Eventable\nend\n")
    statuses = write_file("card/statuses.rb", "module Card::Statuses\nend\n")
    accessible = write_file("accessible.rb", "module Accessible\nend\n")

    index = described_class.new([host, eventable, statuses, accessible])

    expect(index.files_reaching("Eventable"))
      .to contain_exactly(host, statuses, accessible)
  end

  it "retorna vazio para um módulo que ninguém inclui" do
    lonely = write_file("lonely.rb", "module Lonely\nend\n")

    index = described_class.new([lonely])

    expect(index.files_reaching("Lonely")).to be_empty
  end
end
