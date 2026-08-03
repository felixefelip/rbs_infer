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

  it "reaches the host and the target module's sibling concerns" do
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

    # host + both siblings (which never name Eventable)
    expect(index.files_reaching("Eventable"))
      .to contain_exactly(host, publishable, closeable)
  end

  it "resolves multi-line and namespaced includes" do
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

  it "returns empty for a module no one includes" do
    lonely = write_file("lonely.rb", "module Lonely\nend\n")

    index = described_class.new([lonely])

    expect(index.files_reaching("Lonely")).to be_empty
  end

  # felixefelip/rbs_infer#163. What `self` is inside a module, read off the
  # `include`s that are actually written instead of guessed from a convention.
  describe "#hosts_of" do
    it "answers with the class that includes the module" do
      host = write_file("card.rb", "class Card\n  include Card::Entropic\nend\n")
      entropic = write_file("card/entropic.rb", "module Card::Entropic\nend\n")

      index = described_class.new([host, entropic])

      expect(index.hosts_of("Card::Entropic")).to contain_exactly("Card")
    end

    # A module mixed into two classes has two possible `self`s. Naming one would
    # be a claim the code does not make.
    it "answers with every host, not the first" do
      card = write_file("card.rb", "class Card\n  include Eventable\nend\n")
      comment = write_file("comment.rb", "class Comment\n  include Eventable\nend\n")
      eventable = write_file("eventable.rb", "module Eventable\nend\n")

      index = described_class.new([card, comment, eventable])

      expect(index.hosts_of("Eventable")).to contain_exactly("Card", "Comment")
    end

    # Ruby looks a constant up outward through the enclosing namespaces, so the
    # written name is rarely the FQN.
    it "resolves a name written relative to the host's namespace" do
      host = write_file("card.rb", "class Card\n  include Entropic\nend\n")
      entropic = write_file("card/entropic.rb", "module Card::Entropic\nend\n")

      index = described_class.new([host, entropic])

      expect(index.hosts_of("Card::Entropic")).to contain_exactly("Card")
    end

    it "resolves a name written absolutely" do
      host = write_file("card.rb", "class Card\n  include ::Eventable\nend\n")
      eventable = write_file("eventable.rb", "module Eventable\nend\n")

      index = described_class.new([host, eventable])

      expect(index.hosts_of("::Eventable")).to contain_exactly("Card")
      expect(index.hosts_of("Eventable")).to contain_exactly("Card")
    end

    # The short name alone is ambiguous: `ActionController::Base` includes the
    # `ControllerMethods` of Basic, Digest AND Token.
    it "does not answer on a short-name collision" do
      host = write_file("base.rb", <<~RUBY)
        class ActionController::Base
          include ActionController::HttpAuthentication::Token::ControllerMethods
        end
      RUBY
      token = write_file("token.rb", "module ActionController::HttpAuthentication::Token::ControllerMethods\nend\n")

      index = described_class.new([host, token])

      expect(index.hosts_of("ActionController::HttpAuthentication::Basic::ControllerMethods")).to be_empty
      expect(index.hosts_of("ActionController::HttpAuthentication::Token::ControllerMethods"))
        .to contain_exactly("ActionController::Base")
    end

    # A class split across files carries the includes of all of them.
    it "merges the includes of a reopened class" do
      one = write_file("card.rb", "class Card\n  include Eventable\nend\n")
      two = write_file("card_extra.rb", "class Card\n  include Searchable\nend\n")

      index = described_class.new([one, two])

      expect(index.hosts_of("Eventable")).to contain_exactly("Card")
      expect(index.hosts_of("Searchable")).to contain_exactly("Card")
    end

    it "is empty for a module no one includes" do
      lonely = write_file("lonely.rb", "module Lonely\nend\n")

      expect(described_class.new([lonely]).hosts_of("Lonely")).to be_empty
    end
  end
end
