require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/active_record/runtime_generator"
require "tmpdir"
require "fileutils"
require "pathname"

RSpec.describe RbsInfer::Extensions::Rails::ActiveRecord::RuntimeGenerator do
  def in_app(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, content|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      yield dir
    end
  end

  def source_of(result, filename)
    result.find { |f| f.filename == filename }&.source
  end

  # The entries derived from THIS app's models. The framework transcriptions
  # (`ActiveSupport::Concern`) are emitted unconditionally — they describe Rails,
  # not the app — so "nothing was derived from these models" is a statement about
  # what remains once they are set aside, not about the whole result.
  def app_reopens(result)
    result.reject { |f| f.filename == RbsInfer::Extensions::Rails::ActiveRecord::Runtime::ConcernPseudoCode::FILENAME }
  end

  ASSIGNMENT = <<~RUBY
    class Assignment < ApplicationRecord
      belongs_to :post
      belongs_to :owner, class_name: "User"

      before_validation :log_post_user_name

      def log_post_user_name
        post.user.name
      end
    end
  RUBY

  POST = <<~RUBY
    class Post < ApplicationRecord
      has_many :assignments, dependent: :destroy
    end
  RUBY

  describe "model reopen (save flow)" do
    it "runs the before_validation callbacks from save" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")

        expect(model).to include("class Assignment\n")
        expect(model).to match(/def save\(\*\*\)\n\s*run_before_validation_callbacks\n\s*true\n\s*end/)
        expect(model).to match(/def run_before_validation_callbacks\n\s*log_post_user_name\n\s*end/)
        expect(Prism.parse(model).success?).to be(true)
      end
    end

    it "calls every before_validation callback, in order" do
      model_src = <<~RUBY
        class Assignment < ApplicationRecord
          belongs_to :post
          before_validation :a, :b
          before_validation :c, if: :ready?
        end
      RUBY
      in_app("app/models/assignment.rb" => model_src) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")
        expect(model).to match(/def run_before_validation_callbacks\n\s*a\n\s*b\n\s*c\n\s*end/)
      end
    end

    it "reopens a belongs_to `default:` lambda as a before_validation callback" do
      # `belongs_to :owner, default: -> { post.user }` runs its lambda in a
      # before_validation callback (`self.owner ||= post.user`), so the deref of
      # a nilable belongs_to inside it (`post.user`) becomes reachable from save
      # and the contract machinery can narrow it — same flow as a named callback.
      model_src = <<~RUBY
        class Assignment < ApplicationRecord
          belongs_to :post
          belongs_to :owner, class_name: "User", default: -> { post.user }
        end
      RUBY
      in_app("app/models/assignment.rb" => model_src, "app/models/post.rb" => POST) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")

        expect(model).to match(/def run_before_validation_callbacks\n\s*run_belongs_to_default_callbacks\n\s*end/)
        expect(model).to match(/def run_belongs_to_default_callbacks\n\s*run_belongs_to_default_owner\n\s*end/)
        expect(model).to match(/def run_belongs_to_default_owner\n\s*self\.owner \|\|= post\.user\n\s*end/)
        expect(Prism.parse(model).success?).to be(true)
      end
    end

    it "does not reopen a belongs_to without a `default:`" do
      # A plain belongs_to has no default lambda to run, so no callback is emitted
      # for it (only `belongs_to :owner, default:` would produce one).
      plain = "class Assignment < ApplicationRecord\n  belongs_to :post\nend\n"
      in_app("app/models/assignment.rb" => plain, "app/models/post.rb" => POST) do |dir|
        model = source_of(described_class.new(app_dir: dir).build, "assignment.rb")
        # No save flow at all: no before_validation callback and no default lambda.
        expect(model).to be_nil
      end
    end

    it "emits nothing when a has_many's element is not a scanned model" do
      # POST has `has_many :assignments` but Assignment isn't provided here, so
      # its class/proxy can't be modeled — the association is skipped, and with
      # no before_validation callback either, nothing is emitted.
      in_app("app/models/post.rb" => POST) do |dir|
        expect(app_reopens(described_class.new(app_dir: dir).build)).to be_empty
      end
    end
  end

  describe "owner reopen (association getter)" do
    it "returns the owner-specific proxy from the has_many getter, passing self" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        owner = source_of(described_class.new(app_dir: dir).build, "post.rb")

        expect(owner).to include("class Post\n")
        # 2 args (klass, self) to match the real CollectionProxy constructor;
        # `self` is captured as the owner.
        expect(owner).to match(/def assignments\n\s*Post_Assignment::ActiveRecord_Associations_CollectionProxy\.new\(Assignment, self\)\n\s*end/)
        expect(Prism.parse(owner).success?).to be(true)
      end
    end
  end

    # felixefelip/rbs_infer#128. `has_many :recomendacao_vacinas` inside `Caderneta`
    # resolves to `Caderneta::RecomendacaoVacina` when that exists — Ruby looks a constant
    # up from the enclosing namespace outward, and `compute_type` follows suit. Matching on
    # the bare `classify` (`RecomendacaoVacina`) found no scanned model under that name and
    # dropped the association entirely: no getter, no proxy reopen, and
    # `caderneta.recomendacao_vacinas` had no type at all.
    it "resolves a namespaced element from the owner's namespace outward" do
      in_app(
        "app/models/caderneta.rb" => <<~RUBY,
          class Caderneta < ApplicationRecord
            has_many :recomendacao_vacinas, dependent: :destroy, inverse_of: :caderneta
          end
        RUBY
        "app/models/caderneta/recomendacao_vacina.rb" => <<~RUBY
          class Caderneta::RecomendacaoVacina < ApplicationRecord
            belongs_to :caderneta
          end
        RUBY
      ) do |dir|
        owner = source_of(described_class.new(app_dir: dir).build, "caderneta.rb")

        expect(owner).to match(
          /def recomendacao_vacinas\n\s*Caderneta_Caderneta_RecomendacaoVacina::ActiveRecord_Associations_CollectionProxy\.new\(Caderneta::RecomendacaoVacina, self\)/
        )
      end
    end

    # The outward walk must not shadow a top-level element with a same-named nested one
    # that does not exist — `has_many :posts` in `Caderneta` is still `::Post`.
    it "falls through to the top-level element when the owner has no nested one" do
      in_app(
        "app/models/caderneta.rb" => "class Caderneta < ApplicationRecord\n  has_many :posts\nend\n",
        "app/models/post.rb" => "class Post < ApplicationRecord\n  belongs_to :caderneta\nend\n"
      ) do |dir|
        owner = source_of(described_class.new(app_dir: dir).build, "caderneta.rb")

        expect(owner).to match(/Caderneta_Post::ActiveRecord_Associations_CollectionProxy\.new\(Post, self\)/)
      end
    end

  # felixefelip/rbs_infer#139. An association is as often declared in a concern's
  # `included do` as in the model's own body (`has_many :notifications` inside
  # `User::Notifiable`). rbs_rails sees it — it reflects at runtime, where the
  # concern is already included — but this generator reads SOURCE, and reading
  # `user.rb` alone saw no `has_many` at all: no getter, no proxy reopen, and
  # `user.notifications` with no type.
  describe "associations from a concern" do
    NOTIFIABLE = <<~RUBY
      module User::Notifiable
        extend ActiveSupport::Concern

        included do
          has_many :notifications, dependent: :destroy
        end
      end
    RUBY

    USER = <<~RUBY
      class User < ApplicationRecord
        include User::Notifiable
      end
    RUBY

    NOTIFICATION = <<~RUBY
      class Notification < ApplicationRecord
        belongs_to :user
      end
    RUBY

    def concern_app(extra = {})
      in_app({
        "app/models/user.rb" => USER,
        "app/models/user/notifiable.rb" => NOTIFIABLE,
        "app/models/notification.rb" => NOTIFICATION
      }.merge(extra)) { |dir| yield described_class.new(app_dir: dir).build }
    end

    it "emits the getter on the includer, not on the concern" do
      concern_app do |files|
        expect(source_of(files, "user.rb")).to match(
          /class User\n.*def notifications\n\s*User_Notification::ActiveRecord_Associations_CollectionProxy\.new\(Notification, self\)\n\s*end/m
        )
        # The concern is not a model — it owns no association of its own.
        expect(files.map(&:filename)).not_to include("user_notifiable.rb")
      end
    end

    it "emits the proxy reopen with the construction flow" do
      concern_app do |files|
        proxy = source_of(files, "user_notification.rb")
        expect(proxy).to include("class User_Notification::ActiveRecord_Associations_CollectionProxy\n")
        expect(proxy).to match(/def build\(\*\)\n\s*record = Notification\.new\n\s*record\.user = owner\n\s*record\n\s*end/)
      end
    end

    it "resolves a concern written by its bare name from the host's namespace" do
      # `include Notifiable` inside `class User` is `User::Notifiable` — Ruby
      # searches the lexical scope outward, and a concern is conventionally
      # nested under its host.
      concern_app("app/models/user.rb" => "class User < ApplicationRecord\n  include Notifiable\nend\n") do |files|
        expect(source_of(files, "user.rb")).to match(/def notifications\n/)
      end
    end

    it "honours class_name: on a concern's has_many" do
      bundled = <<~RUBY
        module User::Notifiable
          extend ActiveSupport::Concern

          included do
            has_many :notification_bundles, class_name: "Notification::Bundle", dependent: :destroy
          end
        end
      RUBY
      concern_app(
        "app/models/user/notifiable.rb" => bundled,
        "app/models/notification/bundle.rb" => "class Notification::Bundle < ApplicationRecord\n  belongs_to :user\nend\n"
      ) do |files|
        expect(source_of(files, "user.rb")).to match(
          /def notification_bundles\n\s*User_Notification_Bundle::ActiveRecord_Associations_CollectionProxy\.new\(Notification::Bundle, self\)/
        )
      end
    end

    it "splices a concern's before_validation callbacks at the include site" do
      # Rails registers a concern's callbacks when the `include` runs, so they
      # sit between the class's own declarations — the order the pseudo-code
      # must reproduce, since `run_before_validation_callbacks` calls them in
      # sequence.
      concern = <<~RUBY
        module Notification::Stampable
          extend ActiveSupport::Concern

          included do
            before_validation :stamp
          end
        end
      RUBY
      model = <<~RUBY
        class Notification < ApplicationRecord
          before_validation :first
          include Notification::Stampable
          before_validation :last
        end
      RUBY
      concern_app(
        "app/models/notification.rb" => model,
        "app/models/notification/stampable.rb" => concern
      ) do |files|
        expect(source_of(files, "notification.rb")).to match(
          /def run_before_validation_callbacks\n\s*first\n\s*stamp\n\s*last\n\s*end/
        )
      end
    end

    it "keeps a single getter when the concern and the class declare the same association" do
      # A redeclaration replaces the reflection at runtime; emitting both would
      # define `notifications` twice in the reopen, which collides in the
      # inferred RBS.
      both = "class User < ApplicationRecord\n  include User::Notifiable\n  has_many :notifications, dependent: :destroy\nend\n"
      concern_app("app/models/user.rb" => both) do |files|
        expect(source_of(files, "user.rb").scan(/def notifications\n/).size).to eq(1)
      end
    end

    it "follows a concern that includes another concern" do
      outer = <<~RUBY
        module User::Notifiable
          extend ActiveSupport::Concern
          include User::Bundling
        end
      RUBY
      inner = <<~RUBY
        module User::Bundling
          extend ActiveSupport::Concern

          included do
            has_many :notifications, dependent: :destroy
          end
        end
      RUBY
      concern_app(
        "app/models/user/notifiable.rb" => outer,
        "app/models/user/bundling.rb" => inner
      ) do |files|
        expect(source_of(files, "user.rb")).to match(/def notifications\n/)
      end
    end

    it "ignores an include naming something outside the scanned models" do
      # A gem's concern has no source here to read; contributing nothing beats
      # inventing an association.
      concern_app("app/models/user.rb" => "class User < ApplicationRecord\n  include Devise::Models::Trackable\nend\n") do |files|
        expect(files.map(&:filename)).not_to include("user.rb")
      end
    end

    it "does not loop on mutually including concerns" do
      a = "module User::A\n  extend ActiveSupport::Concern\n  include User::B\nend\n"
      b = "module User::B\n  extend ActiveSupport::Concern\n  include User::A\n  included do\n    has_many :notifications\n  end\nend\n"
      concern_app(
        "app/models/user.rb" => "class User < ApplicationRecord\n  include User::A\nend\n",
        "app/models/user/a.rb" => a,
        "app/models/user/b.rb" => b
      ) do |files|
        expect(source_of(files, "user.rb")).to match(/def notifications\n/)
      end
    end
  end

  # felixefelip/rbs_infer#141. A `has_many :through`'s element class is not
  # knowable from the association's name: `has_many :accessible_cards, through:
  # :boards, source: :cards` is `Card`. Guessing `AccessibleCard` found no
  # scanned model, so the association was dropped whole — no getter, no proxy,
  # and `user.accessible_cards` with no type at all. 11 of fizzy's 64 has_many
  # were going out this way.
  describe "has_many :through element resolution" do
    ACCESS = "class Access < ApplicationRecord\n  belongs_to :user\n  belongs_to :board\nend\n"
    BOARD = "class Board < ApplicationRecord\n  has_many :cards\nend\n"
    CARD = "class Card < ApplicationRecord\n  belongs_to :board\n  has_many :comments\nend\n"
    CARD_COMMENT = "class Comment < ApplicationRecord\n  belongs_to :card\nend\n"

    ACCESSOR = <<~RUBY
      class User < ApplicationRecord
        has_many :accesses
        has_many :boards, through: :accesses
        has_many :accessible_cards, through: :boards, source: :cards
        has_many :accessible_comments, through: :accessible_cards, source: :comments
      end
    RUBY

    def accessor_app(extra = {})
      in_app({
        "app/models/user.rb" => ACCESSOR,
        "app/models/access.rb" => ACCESS,
        "app/models/board.rb" => BOARD,
        "app/models/card.rb" => CARD,
        "app/models/comment.rb" => CARD_COMMENT
      }.merge(extra)) { |dir| yield described_class.new(app_dir: dir).build }
    end

    it "reads the element off the `source:` association of the through model" do
      accessor_app do |files|
        expect(source_of(files, "user.rb")).to match(
          /def accessible_cards\n\s*User_Card::ActiveRecord_Associations_CollectionProxy\.new\(Card, self\)/
        )
      end
    end

    it "follows a through whose target is itself a through" do
      # `accessible_comments` hops to `accessible_cards` — a through association
      # too — so the walk has to recurse before it can read `comments` off Card.
      accessor_app do |files|
        expect(source_of(files, "user.rb")).to match(
          /def accessible_comments\n\s*User_Comment::ActiveRecord_Associations_CollectionProxy\.new\(Comment, self\)/
        )
      end
    end

    it "honours class_name: on the source reflection, with no `source:` written" do
      # `has_many :assignees, through: :assignments` takes its element from
      # `Assignment`'s `assignee` reflection — where `class_name: "User"` is
      # written. Nothing in the owner's file spells `User`, which is why the
      # name-based guess (`Assignee`) cannot work even in principle.
      in_app(
        "app/models/post.rb" => "class Post < ApplicationRecord\n  has_many :assignments\n  has_many :assignees, through: :assignments\nend\n",
        "app/models/assignment.rb" => "class Assignment < ApplicationRecord\n  belongs_to :post\n  belongs_to :assignee, class_name: \"User\"\nend\n",
        "app/models/user.rb" => "class User < ApplicationRecord\nend\n"
      ) do |dir|
        expect(source_of(described_class.new(app_dir: dir).build, "post.rb")).to match(
          /def assignees\n\s*Post_User::ActiveRecord_Associations_CollectionProxy\.new\(User, self\)/
        )
      end
    end

    it "resolves an element that declares no association of its own" do
      # `User::DataExport` is a model with nothing but methods. It was absent
      # from the scanned-model table, so `has_many :data_exports` resolved to
      # nothing — the element has to be a known CLASS, not a known association
      # holder.
      in_app(
        "app/models/user.rb" => "class User < ApplicationRecord\n  has_many :data_exports, class_name: \"User::DataExport\"\nend\n",
        "app/models/user/data_export.rb" => "class User::DataExport < Export\n  def filename\n    \"x.zip\"\n  end\nend\n"
      ) do |dir|
        files = described_class.new(app_dir: dir).build
        expect(source_of(files, "user.rb")).to match(
          /def data_exports\n\s*User_User_DataExport::ActiveRecord_Associations_CollectionProxy\.new\(User::DataExport, self\)/
        )
        # It needs no reopen of its own — no callbacks, no has_many.
        expect(files.map(&:filename)).not_to include("user_data_export.rb")
      end
    end

    it "falls back to the conventional name when the through cannot be followed" do
      # `through:` naming a `has_one` (not scanned) or a gem's association leaves
      # the chain unresolvable; the name-based guess is still right for the common
      # `has_many :tags, through: :taggings` shape, so it stays as the fallback.
      in_app(
        "app/models/post.rb" => "class Post < ApplicationRecord\n  has_many :tags, through: :taggings\nend\n",
        "app/models/tag.rb" => "class Tag < ApplicationRecord\n  belongs_to :post\nend\n"
      ) do |dir|
        expect(source_of(described_class.new(app_dir: dir).build, "post.rb")).to match(
          /def tags\n\s*Post_Tag::ActiveRecord_Associations_CollectionProxy\.new\(Tag, self\)/
        )
      end
    end

    it "does not loop on associations that go through each other" do
      # Neither resolves (Rails would raise on this too); the point is that it
      # terminates rather than recursing forever.
      in_app("app/models/loop.rb" => "class Loop < ApplicationRecord\n  has_many :as, through: :bs\n  has_many :bs, through: :as\nend\n") do |dir|
        expect(app_reopens(described_class.new(app_dir: dir).build)).to be_empty
      end
    end
  end

  describe "construction flow through a has_many :through" do
    # `user.pinned_cards.build` does NOT set `card.user` — the row that links
    # them lives on the join, so Active Record leaves the element's belongs_to
    # alone. Emitting `record.user = owner` would hand the contract machinery a
    # fact the runtime never establishes.
    PIN = "class Pin < ApplicationRecord\n  belongs_to :user\n  belongs_to :card\nend\n"
    OWNED_CARD = "class Card < ApplicationRecord\n  belongs_to :user\nend\n"

    it "omits build when the only association reaching the element is a through" do
      through_only = "class User < ApplicationRecord\n  has_many :pins\n  has_many :pinned_cards, through: :pins, source: :card\nend\n"
      in_app("app/models/user.rb" => through_only, "app/models/pin.rb" => PIN, "app/models/card.rb" => OWNED_CARD) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "user_card.rb")

        expect(proxy).to match(/def owner\n\s*@owner\n\s*end/)
        expect(proxy).not_to include("def build")
        expect(proxy).not_to include("record.user = owner")
      end
    end

    it "keeps build when a direct association shares the proxy namespace" do
      # The namespace is per (owner, element) pair, so `cards` and `pinned_cards`
      # are both `User_Card`. The through one is declared first — as a concern's
      # would be, sitting above the class's own macros — and taking the first
      # candidate would cost `user.cards.create` its construction flow.
      both = "class User < ApplicationRecord\n  has_many :pins\n  has_many :pinned_cards, through: :pins, source: :card\n  has_many :cards\nend\n"
      in_app("app/models/user.rb" => both, "app/models/pin.rb" => PIN, "app/models/card.rb" => OWNED_CARD) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "user_card.rb")

        expect(proxy).to match(/def build\(\*\)\n\s*record = Card\.new\n\s*record\.user = owner\n\s*record\n\s*end/)
      end
    end
  end

  describe "a class reopened in several files" do
    it "keeps the reflections of every reopen" do
      # Ruby reopens a class rather than replacing it, so both files register.
      # Indexing by name and letting one win dropped the other's reflections: a
      # `class Post` opened only to nest `Post::Archiver` erased Post's own
      # `belongs_to :user`, and with it `build`'s inverse.
      in_app(
        "app/models/user.rb" => "class User < ApplicationRecord\n  has_many :posts\nend\n",
        "app/models/post.rb" => "class Post < ApplicationRecord\n  belongs_to :user\nend\n",
        "app/models/post/archiver.rb" => "class Post\n  class Archiver\n  end\nend\n"
      ) do |dir|
        expect(source_of(described_class.new(app_dir: dir).build, "user_post.rb")).to include("record.user = owner")
      end
    end
  end

  describe "proxy reopen (construction flow)" do
    it "captures the owner and reopens with build/new/create/create!" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "post_assignment.rb")

        expect(proxy).to include("class Post_Assignment::ActiveRecord_Associations_CollectionProxy\n")
        # initialize(klass, owner) matches the real constructor arity; owner captured.
        expect(proxy).to match(/def initialize\(klass, owner\)\n\s*@owner = owner\n\s*end/)
        expect(proxy).to match(/def owner\n\s*@owner\n\s*end/)
        # build establishes the inverse belongs_to (`post`) from the owner.
        expect(proxy).to match(/def build\(\*\)\n\s*record = Assignment\.new\n\s*record\.post = owner\n\s*record\n\s*end/)
        # create = build (no args, matches the optional overload) + save.
        expect(proxy).to match(/def create\(\*\)\n\s*record = build\n\s*record\.save\n\s*record\n\s*end/)
        # create! delegates to `create` (single `save` call site) rather than
        # repeating build/save — keeps the caller chain linear so a precondition
        # on `save` can enforce (felixefelip/steep#65).
        expect(proxy).to match(/def create!\(\*\)\n\s*create or raise ActiveRecord::RecordInvalid\n\s*end/)
        expect(Prism.parse(proxy).success?).to be(true)
      end
    end

    it "names the proxy <Owner>_<Element> to match rbs_rails" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        expect(described_class.new(app_dir: dir).build.map(&:filename)).to include("post_assignment.rb")
      end
    end

    it "sets the inverse belongs_to whose target is the owner" do
      # Assignment belongs_to :post AND :owner(User); the has_many owner is Post,
      # so the inverse the proxy sets is `post`, not `owner`.
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "post_assignment.rb")
        expect(proxy).to include("record.post = owner")
        expect(proxy).not_to include("record.owner = owner")
      end
    end

    it "emits the proxy for a plain has_many (no before_validation needed)" do
      # rbs_infer owns the getter/proxy for every has_many now, so a plain
      # element (no before_validation) still gets a proxy — with the
      # construction flow, since it has an inverse belongs_to (`post`).
      plain = "class Assignment < ApplicationRecord\n  belongs_to :post\nend\n"
      in_app("app/models/assignment.rb" => plain, "app/models/post.rb" => POST) do |dir|
        files = described_class.new(app_dir: dir).build
        proxy = source_of(files, "post_assignment.rb")
        expect(proxy).not_to be_nil
        expect(proxy).to match(/def build\(\*\)\n\s*record = Assignment\.new\n\s*record\.post = owner\n\s*record\n\s*end/)
        # No save flow for the model — it has no before_validation callback.
        expect(files.map(&:filename)).not_to include("assignment.rb")
        # The owner still gets the getter.
        expect(source_of(files, "post.rb")).to match(/def assignments\n/)
      end
    end

    it "emits an owner-capture-only proxy for a has_many :through (no inverse belongs_to)" do
      # `Post has_many :tags, through: :post_tags` — Tag has no `belongs_to
      # :post`, so there's no inverse to establish: only `initialize`/`owner`.
      post = "class Post < ApplicationRecord\n  has_many :tags, through: :post_tags\nend\n"
      tag  = "class Tag < ApplicationRecord\n  has_many :posts, through: :post_tags\nend\n"
      in_app("app/models/post.rb" => post, "app/models/tag.rb" => tag) do |dir|
        proxy = source_of(described_class.new(app_dir: dir).build, "post_tag.rb")
        expect(proxy).not_to be_nil
        expect(proxy).to match(/def owner\n\s*@owner\n\s*end/)
        expect(proxy).not_to include("def build")
        expect(proxy).not_to include("record.save")
      end
    end
  end

  describe "RBS for invented methods" do
    it "does not hand-write a <Model>.rbs for run_before_validation_callbacks" do
      # The synthetic method is defined in the emitted `.rb`; rbs_infer infers
      # its RBS from that pseudo-code, so no `.rbs` is emitted here (a
      # hand-written one would collide with the inferred declaration).
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        files = described_class.new(app_dir: dir).build
        expect(files.map(&:filename)).not_to include("assignment.rbs")
        expect(files.map(&:filename)).to all(end_with(".rb"))
      end
    end
  end

  # Active Record delegates a model's public class methods to its relations and
  # collection proxies (`Relation#method_missing` compiles them into
  # `<Model>::GeneratedRelationMethods`), and nothing emitted that statically —
  # `user.filters.from_params(…)` was a NoMethodError on the proxy
  # (felixefelip/rbs_infer#185).
  describe "relation reopen (class-method delegation)" do
    APP_RECORD = <<~RUBY
      class ApplicationRecord < ActiveRecord::Base
      end
    RUBY

    def relation_methods_for(files)
      in_app({ "app/models/application_record.rb" => APP_RECORD }.merge(files)) do |dir|
        yield described_class.new(app_dir: dir).build
      end
    end

    it "delegates a `class << self` method to the model" do
      model = <<~RUBY
        class Filter < ApplicationRecord
          class << self
            def from_params(params)
              find_by_params(params)
            end
          end
        end
      RUBY

      relation_methods_for("app/models/filter.rb" => model) do |files|
        source = source_of(files, "filter/generated_relation_methods.rb")

        expect(source).to include("module Filter::GeneratedRelationMethods\n")
        expect(source).to match(/def from_params\(params\)\n\s*::Filter\.from_params\(params\)\n\s*end/)
        expect(Prism.parse(source).success?).to be(true)
      end
    end

    it "keeps the written parameters, so the call sites still type each one" do
      model = <<~RUBY
        class Filter < ApplicationRecord
          def self.remember(attrs, limit = 5, *rest, touch: true, **opts, &blk)
          end
        end
      RUBY

      relation_methods_for("app/models/filter.rb" => model) do |files|
        expect(source_of(files, "filter/generated_relation_methods.rb")).to include(
          "  def remember(attrs, limit = 5, *rest, touch: true, **opts, &blk)\n" \
          "    ::Filter.remember(attrs, limit, *rest, touch: touch, **opts, &blk)\n"
        )
      end
    end

    # A default is copied verbatim into a module whose lexical scope is NOT the
    # model's, so a constant written there would not resolve; the anonymous list
    # keeps the arity without naming anything.
    it "falls back to anonymous parameters when a default names a constant" do
      model = <<~RUBY
        class Filter < ApplicationRecord
          def self.paged(size = PER_PAGE)
          end
        end
      RUBY

      relation_methods_for("app/models/filter.rb" => model) do |files|
        expect(source_of(files, "filter/generated_relation_methods.rb")).to include(
          "  def paged(*, **, &)\n    ::Filter.paged(*, **, &)\n"
        )
      end
    end

    # Rails delegates only PUBLIC class methods (`method_missing` guards on
    # `model.respond_to?`).
    it "skips private class methods" do
      model = <<~RUBY
        class Filter < ApplicationRecord
          def self.kept; end

          class << self
            private
              def hidden; end
          end

          private_class_method def self.also_hidden; end

          def self.hidden_by_symbol; end
          private_class_method :hidden_by_symbol
        end
      RUBY

      relation_methods_for("app/models/filter.rb" => model) do |files|
        source = source_of(files, "filter/generated_relation_methods.rb")

        expect(source).to include("def kept")
        expect(source).not_to include("hidden")
      end
    end

    # rbs_rails already writes the scopes into this very module, and a duplicate
    # definition in one module poisons the whole RBS environment.
    it "leaves a name rbs_rails already emits as a scope alone" do
      model = <<~RUBY
        class Filter < ApplicationRecord
          scope :recent, -> { order(created_at: :desc) }

          def self.recent; end
          def self.oldest; end
        end
      RUBY

      relation_methods_for("app/models/filter.rb" => model) do |files|
        source = source_of(files, "filter/generated_relation_methods.rb")

        expect(source).to include("def oldest")
        expect(source).not_to include("def recent")
      end
    end

    # A concern's class methods are INCLUDED rather than delegated: the includer's
    # own RBS never re-declares them (nothing emits the `extend` that
    # ActiveSupport::Concern performs), so `Filter.find_by_params` would not
    # resolve — but `Filter::Params::ClassMethods` already carries the signatures.
    it "includes a concern's ClassMethods module, both spellings" do
      block_form = <<~RUBY
        module Filter::Params
          extend ActiveSupport::Concern
          class_methods do
            def find_by_params(params); end
          end
        end
      RUBY
      module_form = <<~RUBY
        module Filter::Sorting
          extend ActiveSupport::Concern
          module ClassMethods
            def sorted_by(key); end
          end
        end
      RUBY
      model = <<~RUBY
        class Filter < ApplicationRecord
          include Filter::Params
          include Filter::Sorting
        end
      RUBY

      relation_methods_for(
        "app/models/filter.rb" => model,
        "app/models/filter/params.rb" => block_form,
        "app/models/filter/sorting.rb" => module_form
      ) do |files|
        source = source_of(files, "filter/generated_relation_methods.rb")

        expect(source).to include("  include ::Filter::Params::ClassMethods\n")
        expect(source).to include("  include ::Filter::Sorting::ClassMethods\n")
        expect(source).not_to include("def find_by_params")
      end
    end

    # The reopen sits inside the model's own namespace, where a relative name is
    # resolved against it first: `include Storage::Totaled::ClassMethods` inside
    # `class Account` means `::Account::Storage::Totaled::ClassMethods` as soon as
    # `Account::Storage` exists, and RBS then fails with `Cannot find type
    # Storage::Totaled::ClassMethods` (felixefelip/rbs_infer#185).
    it "writes every constant absolute, so the model's own namespace cannot capture it" do
      concern = <<~RUBY
        module Storage::Totaled
          extend ActiveSupport::Concern
          class_methods do
            def foreign_key_for_storage; end
          end
        end
      RUBY
      shadow = "module Account::Storage\nend\n"
      model = <<~RUBY
        class Account < ApplicationRecord
          include Storage::Totaled

          def self.create_with_owner(owner:); end
        end
      RUBY

      relation_methods_for(
        "app/models/account.rb" => model,
        "app/models/account/storage.rb" => shadow,
        "app/models/concerns/storage/totaled.rb" => concern
      ) do |files|
        source = source_of(files, "account/generated_relation_methods.rb")

        expect(source).to include("  include ::Storage::Totaled::ClassMethods\n")
        expect(source).to include("    ::Account.create_with_owner(owner: owner)\n")
      end
    end

    # `GeneratedRelationMethods` is an Active Record concept — a plain class under
    # `app/models` has no relation to delegate to.
    it "emits nothing for a class that is not a model" do
      service = <<~RUBY
        class PlainService
          def self.call(x); end
        end
      RUBY

      relation_methods_for("app/models/plain_service.rb" => service) do |files|
        expect(files.map(&:filename)).not_to include("plain_service/generated_relation_methods.rb")
      end
    end

    # An STI child reaches ActiveRecord::Base through its parent, not directly.
    it "follows the superclass chain to decide a class is a model" do
      parent = <<~RUBY
        class Filter < ApplicationRecord
        end
      RUBY
      child = <<~RUBY
        class SavedFilter < Filter
          def self.from_params(params); end
        end
      RUBY

      relation_methods_for(
        "app/models/filter.rb" => parent, "app/models/saved_filter.rb" => child
      ) do |files|
        expect(source_of(files, "saved_filter/generated_relation_methods.rb"))
          .to include("module SavedFilter::GeneratedRelationMethods\n")
      end
    end
  end

  describe "store accessors" do
    def store_app(model, extra = {})
      in_app({ "app/models/setting.rb" => model }.merge(extra)) do |dir|
        yield described_class.new(app_dir: dir).build
      end
    end

    it "emits a reader/writer pair per key, backed by one ivar per store slot" do
      store_app(<<~RUBY) do |files|
        class Setting < ApplicationRecord
          store_accessor :payload, :theme, :locale
        end
      RUBY
        expect(source_of(files, "setting/generated_store_accessors.rb")).to eq(<<~RUBY)
          # frozen_string_literal: true
          #
          # GENERATED by RbsInfer::Extensions::Rails::ActiveRecord::RuntimeGenerator.
          # Regenerated on every run; do not edit.

          module Setting::GeneratedStoreAccessors
            def theme
              @__store_payload_theme
            end

            def theme=(value)
              @__store_payload_theme = value
            end

            def locale
              @__store_payload_locale
            end

            def locale=(value)
              @__store_payload_locale = value
            end
          end
        RUBY
      end
    end

    # Active Record includes `_store_accessors_module` rather than defining the
    # pair on the class, which is the whole reason an override in the class body
    # can call `super`. Emitting `def theme` on the class would shadow the
    # override instead of backing it.
    it "includes the module on the model rather than defining the pair on it" do
      store_app(<<~RUBY) do |files|
        class Setting < ApplicationRecord
          store_accessor :payload, :theme
        end
      RUBY
        expect(source_of(files, "setting.rb")).to include("class Setting\n  include ::Setting::GeneratedStoreAccessors\n")
        expect(source_of(files, "setting.rb")).not_to include("def theme")
      end
    end

    it "names the method with prefix:/suffix: while the slot keeps the bare key" do
      store_app(<<~RUBY) do |files|
        class Setting < ApplicationRecord
          store_accessor :payload, :theme, prefix: true
          store_accessor :payload, :locale, suffix: :config
          store_accessor :payload, :zone, prefix: "ui"
        end
      RUBY
        source = source_of(files, "setting/generated_store_accessors.rb")
        expect(source).to include("def payload_theme\n    @__store_payload_theme\n")
        expect(source).to include("def locale_config\n    @__store_payload_locale\n")
        expect(source).to include("def ui_zone\n    @__store_payload_zone\n")
      end
    end

    it "flattens an array of keys the way Active Record does" do
      store_app(<<~RUBY) do |files|
        class Setting < ApplicationRecord
          store_accessor :payload, %i[theme locale]
        end
      RUBY
        source = source_of(files, "setting/generated_store_accessors.rb")
        expect(source).to include("def theme\n")
        expect(source).to include("def locale\n")
      end
    end

    it "reads the pairs off `store ... accessors:` too" do
      store_app(<<~RUBY) do |files|
        class Setting < ApplicationRecord
          store :payload, accessors: [ :theme ], coder: JSON
        end
      RUBY
        expect(source_of(files, "setting/generated_store_accessors.rb")).to include("def theme\n")
      end
    end

    # `store :request, coder: JSON` declares the serialization and nothing else —
    # it defines no method, so there is no pair to model.
    it "emits nothing for a store that declares no accessors" do
      store_app(<<~RUBY) do |files|
        class Setting < ApplicationRecord
          store :payload, coder: JSON
        end
      RUBY
        expect(files.map(&:filename)).not_to include("setting/generated_store_accessors.rb")
      end
    end

    # The keys belong to whoever includes the concern — Rails runs `included do`
    # against the includer, so the module is the INCLUDER's.
    it "splices a concern's keys onto the includer" do
      store_app(<<~RUBY, "app/models/setting/themed.rb" => <<~CONCERN) do |files|
        class Setting < ApplicationRecord
          include Setting::Themed
        end
      RUBY
        module Setting::Themed
          extend ActiveSupport::Concern

          included do
            store_accessor :payload, :theme
          end
        end
      CONCERN
        expect(source_of(files, "setting/generated_store_accessors.rb"))
          .to include("module Setting::GeneratedStoreAccessors\n")
        expect(files.map(&:filename)).not_to include("setting_themed/generated_store_accessors.rb")
      end
    end

    # A redeclared key redefines one method; two entries under one name would be
    # a `DuplicateMethodDefinition`, which poisons the whole RBS environment.
    it "emits one pair per method name when a key is declared twice" do
      store_app(<<~RUBY) do |files|
        class Setting < ApplicationRecord
          store_accessor :payload, :theme
          store_accessor :payload, :theme
        end
      RUBY
        expect(source_of(files, "setting/generated_store_accessors.rb").scan("def theme\n").size).to eq(1)
      end
    end
  end

  # Snapshot of the generated sidecar against the real dummy app, so a change in
  # the emitted pseudo-code shows up as a reviewable diff.
  #   Regenerate with: UPDATE_EXPECTATIONS=1 bundle exec rspec <this file>
  describe "dummy snapshot" do
    let(:expectations) { Pathname(DUMMY_APP_ROOT).dirname.join("expectations/steep_ar_runtime") }

    it "matches the expected files for every generated class" do
      files = described_class.new(app_dir: DUMMY_APP_ROOT).build

      if ENV["UPDATE_EXPECTATIONS"]
        # `.rb` only: the inferred `.rbs` snapshots share this directory
        # (spec/integration/rails_dummy_spec.rb) and rmtree would take them out.
        expectations.glob("**/*.rb").each(&:delete) if expectations.exist?
        files.each do |f|
          path = expectations.join(f.filename)
          path.dirname.mkpath
          path.write(f.source)
        end
      end

      aggregate_failures do
        files.each { |f| expect(f.source).to eq(expectations.join(f.filename).read) }
        # no stale/extra expectation files. Globbed rather than listed: a
        # filename can name a subdirectory (`post/generated_relation_methods.rb`),
        # and `children` would neither see it nor the stale dir it was left in.
        #
        # `.rb` only: the inferred `.rbs` snapshots live in this same directory
        # (spec/integration/rails_dummy_spec.rb, "runtime pseudo-code RBS") and are
        # not this generator's output.
        pseudo_code = expectations.glob("**/*.rb").map { |p| p.relative_path_from(expectations).to_s }
        expect(pseudo_code.sort).to eq(files.map(&:filename).sort)
      end
    end
  end

  # The transcriptions of what Rails itself runs. They answer `included do` the same
  # way whether or not this app writes one, so they are not derived from the models —
  # gating them on a model would make the first app file to write one the thing that
  # made them appear.
  describe "framework transcriptions" do
    it "emits ActiveSupport::Concern for an app with no models at all" do
      in_app({}) do |dir|
        expect(described_class.new(app_dir: dir).build.map(&:filename)).to eq(["active_support/concern.rb"])
      end
    end
  end

  describe "#generate (disk)" do
    # Globbed rather than `Dir.children`, which would see the directory a
    # framework transcription lives in rather than the file itself.
    def written(out)
      Pathname(out).glob("**/*.rb").map { |p| p.relative_path_from(Pathname(out)).to_s }.sort
    end

    it "writes one file per reopened class and removes a stale dir" do
      in_app("app/models/assignment.rb" => ASSIGNMENT, "app/models/post.rb" => POST) do |dir|
        stale = File.join(dir, described_class::SIDECAR_DIR)
        FileUtils.mkdir_p(stale)
        File.write(File.join(stale, "Old.rb"), "old")

        out = described_class.new(app_dir: dir).generate
        expect(written(out)).to eq(["active_support/concern.rb", "assignment.rb", "post.rb", "post_assignment.rb"])
      end
    end

    # The framework transcriptions describe Rails, so a run with nothing to
    # derive from the app still has something to say. What it has to drop is the
    # stale file, not the directory.
    it "removes a stale file when no model qualifies" do
      in_app("app/models/post.rb" => POST) do |dir|
        out = File.join(dir, described_class::SIDECAR_DIR)
        FileUtils.mkdir_p(out)
        File.write(File.join(out, "Stale.rb"), "stale")

        described_class.new(app_dir: dir).generate
        expect(written(out)).to eq(["active_support/concern.rb"])
      end
    end
  end
end
