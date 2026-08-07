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

    # felixefelip/rbs_infer#189. Ruby stops at the first constant it finds
    # walking outward, so a nested module of the host's own namespace shadows
    # the top-level one of the same name — the include never reaches it.
    it "stops at the innermost declared module of the same name" do
      user = write_file("user.rb", "class User\n  include Notifiable\nend\n")
      event = write_file("event.rb", "class Event\n  include Notifiable\nend\n")
      nested = write_file("user/notifiable.rb", "module User::Notifiable\nend\n")
      top = write_file("concerns/notifiable.rb", "module Notifiable\nend\n")

      index = described_class.new([user, event, nested, top])

      expect(index.hosts_of("User::Notifiable")).to contain_exactly("User")
      # `Event::Notifiable` does not exist, so `Event` does reach the top-level
      # one — and `User` does not.
      expect(index.hosts_of("Notifiable")).to contain_exactly("Event")
    end

    # The rooted name says outright which module it means, so the host's own
    # namespace is not searched even when it holds one of the same name.
    it "does not resolve an absolute name into the host's namespace" do
      user = write_file("user.rb", "class User\n  include ::Notifiable\nend\n")
      nested = write_file("user/notifiable.rb", "module User::Notifiable\nend\n")
      top = write_file("concerns/notifiable.rb", "module Notifiable\nend\n")

      index = described_class.new([user, nested, top])

      expect(index.hosts_of("Notifiable")).to contain_exactly("User")
      expect(index.hosts_of("User::Notifiable")).to be_empty
    end

    # Nothing in the sources declares a gem's module, and a name we cannot
    # resolve must not be narrowed away: every candidate stays a host.
    it "keeps every candidate for a module the sources do not declare" do
      host = write_file("card.rb", "class Card\n  include Broadcastable\nend\n")

      index = described_class.new([host])

      expect(index.hosts_of("Broadcastable")).to contain_exactly("Card")
      expect(index.hosts_of("Card::Broadcastable")).to contain_exactly("Card")
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

    # felixefelip/rbs_infer#167. A MODULE that includes the target is another
    # mixin, not a `self`: the real self is whoever includes IT. Fizzy's
    # `Authentication` is included by a concern, and answering that concern put
    # a module where only a class can stand.
    it "resolves through a module that re-mixes the target" do
      host = write_file("application_controller.rb", "class ApplicationController\n  include Authorize\nend\n")
      authorize = write_file("authorize.rb", "module Authorize\n  include Authentication\nend\n")
      auth = write_file("authentication.rb", "module Authentication\nend\n")

      index = described_class.new([host, authorize, auth])

      expect(index.hosts_of("Authentication")).to contain_exactly("ApplicationController")
    end

    it "keeps the class hosts alongside a re-mixed one" do
      app = write_file("application_controller.rb", "class ApplicationController\n  include Authentication\nend\n")
      other = write_file("passkeys_controller.rb", "class PasskeysController\n  include Authentication\nend\n")
      authorize = write_file("authorize.rb", "module Authorize\n  include Authentication\nend\n")
      auth = write_file("authentication.rb", "module Authentication\nend\n")

      index = described_class.new([app, other, authorize, auth])

      # `Authorize` resolves to nothing here — nobody includes it — and drops
      # out rather than standing in for a class.
      expect(index.hosts_of("Authentication")).to contain_exactly("ApplicationController", "PasskeysController")
    end

    # Two concerns including each other must not recurse forever.
    it "survives a cycle" do
      a = write_file("a.rb", "module A\n  include B\nend\n")
      b = write_file("b.rb", "module B\n  include A\nend\n")

      expect(described_class.new([a, b]).hosts_of("A")).to be_empty
    end

    it "is empty for a module no one includes" do
      lonely = write_file("lonely.rb", "module Lonely\nend\n")

      expect(described_class.new([lonely]).hosts_of("Lonely")).to be_empty
    end

    # The answer is memoized and the cycle guard is now threaded through the
    # recursion rather than rebuilt per call, so a second question must not see
    # the first one's `seen` set — which would silently answer empty.
    it "answers the same on repeat, and after resolving through a neighbour" do
      app = write_file("application_controller.rb", "class ApplicationController\n  include Authorize\nend\n")
      authorize = write_file("authorize.rb", "module Authorize\n  include Authentication\nend\n")
      auth = write_file("authentication.rb", "module Authentication\nend\n")

      index = described_class.new([app, authorize, auth])

      expect(index.hosts_of("Authentication")).to contain_exactly("ApplicationController")
      # Asked again, and asked about the module the first answer resolved through.
      expect(index.hosts_of("Authentication")).to contain_exactly("ApplicationController")
      expect(index.hosts_of("Authorize")).to contain_exactly("ApplicationController")
      expect(index.hosts_of("Authentication")).to contain_exactly("ApplicationController")
    end

    # A cycle is `seen`-guarded per question. The guard must not outlive it: the
    # empty answer for `A` says nothing about `B`.
    it "keeps a cycle's guard local to the question" do
      a = write_file("a.rb", "module A\n  include B\nend\n")
      b = write_file("b.rb", "module B\n  include A\nend\n")
      host = write_file("widget.rb", "class Widget\n  include B\nend\n")

      index = described_class.new([a, b, host])

      expect(index.hosts_of("A")).to contain_exactly("Widget")
      expect(index.hosts_of("B")).to contain_exactly("Widget")
    end
  end
end
