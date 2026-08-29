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

    # The include belongs to the declaration that WROTE it, not to the file's
    # headline class. Attributing a whole file to `extractor.class_name` made a
    # nested module's host come out as the outer namespace — for
    # `class Example3; class Foo; module GeneratedAttributes` it answered
    # `Example3`, which includes nothing.
    it "attributes an include to the declaration that writes it, not the file" do
      file = write_file("example3.rb", <<~RUBY)
        class Example3
          class Foo
            module GeneratedAttributes
            end

            include GeneratedAttributes
          end
        end
      RUBY

      index = described_class.new([file])

      expect(index.hosts_of("Example3::Foo::GeneratedAttributes")).to contain_exactly("Example3::Foo")
    end
  end

  describe "#extenders_of" do
    it "answers with the class whose singleton gets the module" do
      file = write_file("bar.rb", "class Bar\n  extend Foo\nend\n")
      foo = write_file("foo.rb", "module Foo\nend\n")

      index = described_class.new([file, foo])

      expect(index.extenders_of("Foo")).to contain_exactly("Bar")
      # `extend` is not an `include`: the module never reaches Bar's instances.
      expect(index.hosts_of("Foo")).to be_empty
    end

    # A module is as good an answer as a class, and is NOT resolved through the
    # way an INCLUDING module is: `module Baz; extend Foo` makes the object
    # `Baz` itself the receiver of Foo's methods, so Baz is the self.
    it "keeps a module that extends the target as the answer" do
      baz = write_file("baz.rb", "module Baz\n  extend Foo\nend\n")
      foo = write_file("foo.rb", "module Foo\nend\n")

      index = described_class.new([baz, foo])

      expect(index.extenders_of("Foo")).to contain_exactly("Baz")
    end

    it "answers with every extender, not the first" do
      file = write_file("example23.rb", <<~RUBY)
        class Example23
          module Foo
          end

          module Baz
            extend Example23::Foo
          end

          class Bar
            extend Example23::Foo
          end
        end
      RUBY

      index = described_class.new([file])

      expect(index.extenders_of("Example23::Foo"))
        .to contain_exactly("Example23::Bar", "Example23::Baz")
    end

    # `include` inside `class << self` puts the module on the singleton, which
    # is what `extend` means — the two spellings produce the same ancestors.
    it "reads an include inside `class << self` as an extend" do
      file = write_file("bar.rb", <<~RUBY)
        class Bar
          class << self
            include Foo
          end
        end
      RUBY
      foo = write_file("foo.rb", "module Foo\nend\n")

      index = described_class.new([file, foo])

      expect(index.extenders_of("Foo")).to contain_exactly("Bar")
      expect(index.hosts_of("Foo")).to be_empty
    end

    # `class C; extend M; end` where `module M; include Foo; end` — C's
    # singleton gets M, and M carries Foo.
    it "reaches the target through a module the extender extends" do
      c = write_file("c.rb", "class C\n  extend M\nend\n")
      m = write_file("m.rb", "module M\n  include Foo\nend\n")
      foo = write_file("foo.rb", "module Foo\nend\n")

      index = described_class.new([c, m, foo])

      expect(index.extenders_of("Foo")).to contain_exactly("C")
    end

    # A class that INCLUDES the target passes it to its instances, never to its
    # singleton — so it is a host, not an extender.
    it "does not read an including class as an extender" do
      card = write_file("card.rb", "class Card\n  include Foo\nend\n")
      foo = write_file("foo.rb", "module Foo\nend\n")

      index = described_class.new([card, foo])

      expect(index.extenders_of("Foo")).to be_empty
      expect(index.hosts_of("Foo")).to contain_exactly("Card")
    end

    # `extend self` names no other host, and its argument is not a constant.
    it "records nothing for `extend self`" do
      file = write_file("foo.rb", "module Foo\n  extend self\nend\n")

      index = described_class.new([file])

      expect(index.extenders_of("Foo")).to be_empty
    end

    # A file that only EXTENDS the module still makes bare calls into it —
    # `bazinga(Baz)` in a class body is a call on the class object.
    it "makes an extending file reach the module" do
      bar = write_file("bar.rb", "class Bar\n  extend Foo\n  bazinga(Baz)\nend\n")
      foo = write_file("foo.rb", "module Foo\n  def bazinga(m) = nil\nend\n")

      index = described_class.new([bar, foo])

      expect(index.files_reaching("Foo")).to include(bar)
    end
  end

  # The include chain is not always written in Ruby. A generated `.rbs` can
  # declare a module and what it mixes in — `ActionViewContext` includes every
  # Rails helper — and a file including THAT reaches the far end of the chain
  # without ever naming it.
  describe "a chain running through a module declared only in RBS" do
    around do |example|
      Dir.chdir(@dir) do
        RbsInfer::Signatures::SteepEnvironment.reset!
        example.run
      end
      RbsInfer::Signatures::SteepEnvironment.reset!
    end

    it "reaches a module carried by an RBS-only mixin" do
      write_file("sig/generated/context.rbs", <<~RBS)
        module ViewContext
          include Sharable
        end

        module Sharable
          def badge: (untyped) -> void
        end
      RBS
      sharable = write_file("sharable.rb", "module Sharable\n  def badge(x) = nil\nend\n")
      template = write_file("template.rb", "class Template\n  include ViewContext\n  badge(thing)\nend\n")

      index = described_class.new([sharable, template])

      expect(index.files_reaching("Sharable")).to include(template)
    end

    # The RBS half is additive. A cold run has no generated `sig/` yet, and an
    # environment that cannot answer must leave the source-derived answer
    # standing rather than reading as "this mixin carries nothing".
    it "still reaches what the source alone shows when RBS knows nothing" do
      sharable = write_file("sharable.rb", "module Sharable\n  def badge(x) = nil\nend\n")
      direct = write_file("direct.rb", "class Direct\n  include Sharable\n  badge(thing)\nend\n")
      template = write_file("template.rb", "class Template\n  include ViewContext\n  badge(thing)\nend\n")

      index = described_class.new([sharable, direct, template])

      expect(index.files_reaching("Sharable")).to include(direct)
      expect(index.files_reaching("Sharable")).not_to include(template)
    end
  end
end
