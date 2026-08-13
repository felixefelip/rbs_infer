# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/current_attributes_runtime_generator"
# Registers the ERB path -> class convention (`Project::SourceOwners`). The CLI requires
# it for real runs; the in-process specs have to do the same, or templates are read as
# sources but belong to no class and are never selected as callers.
require "rbs_infer/extensions/rails/views/erb_source_owner"

RSpec.describe "Rails dummy app integration", :dummy_app do
  # `.erb` belongs here for the same reason `.rb` does: a template's calls are call sites,
  # and since the ERB-as-source-format work they are read like any other source. Helper
  # parameters are typed from exactly those call sites.
  # Mirrors how the CLI is invoked (`rbs_infer app/ sig/`): `.erb` because a template's
  # calls are call sites like any other, and `sig/` because the runtime pseudo-code lives
  # there — it is what gives a template's class its ivars and its `include`s.
  let(:source_files) { Dir["app/**/*.rb"] + Dir["app/**/*.erb"] + Dir["sig/**/*.rb"] }
  let(:expectations_dir) { Pathname.new(File.expand_path("../expectations", __dir__)) }

  # Generate sig/rbs_rails/ types once before running snapshot tests
  before(:all) do
    Dir.chdir(DUMMY_APP_ROOT) do
      Bundler.with_unbundled_env do
        system("bundle", "install", "--quiet", exception: true)
        system("bundle", "exec", "rake", "db:create", "db:migrate", "RAILS_ENV=development", exception: true, out: File::NULL, err: File::NULL)
        system("bundle", "exec", "rake", "rbs_rails:all", exception: true, out: File::NULL, err: File::NULL)
        system("bundle", "exec", "rbs", "collection", "install", exception: true, out: File::NULL, err: File::NULL)
      end
    end
  end

  def generate_rbs(target_class:, target_file:, **kwargs)
    RbsInfer::Analyzer.new(
      target_class: target_class,
      target_file: target_file,
      source_files: source_files,
      **kwargs
    ).generate_rbs
  end

  def expected_rbs(name)
    expectations_dir.join("#{name}.rbs").read
  end

  # To regenerate expectations after intentional changes:
  #   UPDATE_EXPECTATIONS=1 bundle exec rspec spec/integration/
  def assert_snapshot(name, target_class:, target_file:, **kwargs)
    rbs = generate_rbs(target_class: target_class, target_file: target_file, **kwargs)

    if ENV["UPDATE_EXPECTATIONS"]
      expectations_dir.join("#{name}.rbs").write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  it "User model matches expected RBS" do
    assert_snapshot("models/user", target_class: "User", target_file: "app/models/user.rb")
  end

  it "Post model matches expected RBS" do
    assert_snapshot("models/post", target_class: "Post", target_file: "app/models/post.rb")
  end

  # Everything Devise contributes to this model is invisible to the parser — `devise`
  # mixes its modules in at class-definition time. What the snapshot pins is that the
  # analyzer emits the model's OWN members and nothing speculative for the macro.
  it "Account model matches expected RBS" do
    assert_snapshot("models/account", target_class: "Account", target_file: "app/models/account.rb")
  end

  it "Comment model matches expected RBS" do
    assert_snapshot("models/comment", target_class: "Comment", target_file: "app/models/comment.rb")
  end

  it "Tag model matches expected RBS" do
    assert_snapshot("models/tag", target_class: "Tag", target_file: "app/models/tag.rb")
  end

  it "Notification model matches expected RBS" do
    assert_snapshot("models/notification", target_class: "Notification", target_file: "app/models/notification.rb")
  end

  it "PostTag model matches expected RBS" do
    assert_snapshot("models/post_tag", target_class: "PostTag", target_file: "app/models/post_tag.rb")
  end

  # `assigned?` is the nilable-receiver predicate: `post` is `::Post?`, and the
  # nil branch of `present?` is what the resolver used to drop.
  it "Assignment model matches expected RBS" do
    assert_snapshot("models/assignment", target_class: "Assignment", target_file: "app/models/assignment.rb")
  end

  it "Current (CurrentAttributes) matches expected RBS" do
    assert_snapshot("models/current", target_class: "Current", target_file: "app/models/current.rb")
  end

  it "Palette (class constants) matches expected RBS" do
    assert_snapshot("models/palette", target_class: "Palette", target_file: "app/models/palette.rb")
  end

  # `class_eval` / `module_eval` with a constant receiver: plain Ruby, statically
  # decidable, and read by NEITHER repo today — the snapshot records the gap. Every
  # method defined inside the blocks is absent here, and `steep check` attributes
  # them to `::Object` (four entries in `steep_baseline.txt`).
  #
  # `EvalReopen::Slots` next door is fully typed (`slot: () -> String?`), so the
  # `super` inside the `class_eval` block has a real target waiting for it: this is
  # the same shape as a store-accessor override in a concern's `included do`, which
  # Rails implements *as* a `class_eval` on the includer.
  it "EvalReopen (class_eval reopen) matches expected RBS" do
    assert_snapshot("models/eval_reopen", target_class: "EvalReopen", target_file: "app/models/eval_reopen.rb")
  end

  it "EvalReopen::Slots (the class_eval block's super target) matches expected RBS" do
    assert_snapshot("models/eval_reopen/slots", target_class: "EvalReopen::Slots",
                    target_file: "app/models/eval_reopen/slots.rb")
  end

  # `Module#included` is a plain Ruby hook: `include X` calls `X.included(self)`, so
  # `base.class_eval do ... end` inside it defines the block's methods on the INCLUDER.
  # The snapshot records the gap — they are attributed to the module instead, which is
  # why `slot`'s `super` finds nothing and `IncludedHookCaller#read_slot` reads
  # `untyped` where the slot is `String?`.
  #
  # This is the plain-Ruby core of the `included do` problem; ActiveSupport::Concern is
  # sugar over the same shape. `ClassEvalExpander` declines it correctly for what it
  # knows: the receiver is a method parameter, so the call names no class — the hosts
  # have to come from the mixin graph.
  it "IncludedHook (self.included hook) matches expected RBS" do
    assert_snapshot("models/included_hook", target_class: "IncludedHook",
                    target_file: "app/models/included_hook.rb")
  end

  it "IncludedHook::Slots (the hook block's super target) matches expected RBS" do
    assert_snapshot("models/included_hook/slots", target_class: "IncludedHook::Slots",
                    target_file: "app/models/included_hook/slots.rb")
  end

  # `send` with a literal symbol reaching a PRIVATE method — how MRI itself invokes the
  # mixin hooks (`rb_funcall` ignores visibility, and `included`/`append_features` are
  # private on `Module`), which is why the `Module#include` pseudo-code spells them that
  # way. Nothing here is undecidable: the receiver's type is known and the name is a
  # literal. The snapshot records both gaps — `stamp`'s parameter reads `untyped` because
  # rbs_infer indexes the file under `send` and never looks at the call site, and every
  # `#stamped`/`#called` reads `untyped` because Steep types `send` as `untyped` and so
  # checks nothing inside it. `#dynamic` is the limit case and must stay `untyped`.
  it "SendDispatch (send reaching a private method) matches expected RBS" do
    assert_snapshot("models/send_dispatch", target_class: "SendDispatch",
                    target_file: "app/models/send_dispatch.rb")
  end

  # The call-site half, where the checker's answer shows: every one of these is the type
  # of a `send`, so every one reads `untyped` while `send` returns `untyped`. `#dynamic`
  # is the one that has to keep reading it.
  it "SendDispatchCaller (the send call sites) matches expected RBS" do
    assert_snapshot("models/send_dispatch_caller", target_class: "SendDispatchCaller",
                    target_file: "app/models/send_dispatch.rb")
  end

  # A namespaced service object called by its BARE name from the model that
  # encloses it (felixefelip/rbs_infer#129). The interesting half is `Post#archive` /
  # `#archive_via_singleton` in the Post snapshot above: `Archiver` there is
  # `Post::Archiver`, resolved from the enclosing namespace outward.
  it "Post::Archiver (namespaced service) matches expected RBS" do
    assert_snapshot("models/post/archiver", target_class: "Post::Archiver", target_file: "app/models/post/archiver.rb")
  end

  # The same shape one namespace over, and the half `Archiver` cannot show: the
  # caller is a CONCERN, so `self` is not the enclosing constant but whoever
  # includes it. The lexical answer `Post::Taggable` has `tag_names` and not
  # `published_at`; the annotators' `Post & Post::Taggable` has both, and this
  # snapshot is where the difference shows (felixefelip/rbs_infer#161).
  it "Post::TagDigest (self handed out by a concern) matches expected RBS" do
    assert_snapshot("models/post/tag_digest", target_class: "Post::TagDigest", target_file: "app/models/post/tag_digest.rb")
  end

  it "Coupon::Code (constant argument) matches expected RBS" do
    assert_snapshot("models/coupon/code", target_class: "Coupon::Code", target_file: "app/models/coupon/code.rb")
  end

  it "CborLike (value constant in value position) matches expected RBS" do
    assert_snapshot("models/cbor_like", target_class: "CborLike", target_file: "app/models/cbor_like.rb")
  end

  it "Current runtime reopen (pseudo-code) matches expected source" do
    # Snapshot of the desugar itself, separate from the RBS snapshot: a new bug
    # points straight to the right layer — reopen changes → generator bug;
    # identical reopen with a changed RBS → inference pipeline bug. The
    # `CurrentAttributesRuntimeGenerator` reopen is now BOTH the RBS-inference
    # source and the Steep-checked pseudo-code (felixefelip/steep#68 item 5).
    files = RbsInfer::Extensions::Rails::CurrentAttributesRuntimeGenerator.new(app_dir: ".").build
    reopen = files.find { |f| f[:filename] == "current.rb" }

    expect(reopen).not_to be_nil
    expect(Prism.parse(reopen[:source]).success?).to be(true)

    expectation_path = expectations_dir.join("steep_current_runtime/current.rb")
    if ENV["UPDATE_EXPECTATIONS"]
      expectation_path.dirname.mkpath
      expectation_path.write(reopen[:source])
    end

    expect(reopen[:source]).to eq(expectation_path.read)
  end

  # Multi-class fixture exercising the class-scoping fixes end to end
  # (felixefelip/rbs_infer#69, #70): three classes in one file. Without
  # scoping, `Board#initialize`'s `@user_name` leaked into a bogus
  # `Column::AfterInitialize`, `Column`'s `@column_name` leaked onto
  # `Board`/`Example`, and a local `board` in `Example.run` typed
  # `Column#board` as a non-nil `Board`. No target_class → the analyzer
  # discovers and emits all three classes.
  it "multi-class example file matches expected RBS (class scoping)" do
    name = "models/example"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Nested classes reached through an INSTANCE, the counterpart to the
  # singleton delegation in example3. What this pins down:
  #
  # - `Example2::User`/`Example2::Foo` are emitted as separate targets, not
  #   flattened into `Example2` — which used to claim their `initialize`,
  #   both `name` attrs (colliding), and their `@name`/`@user` ivars.
  # - `foo.user = user` in `Example2.run` types `def user=`'s param as `User`,
  #   resolved relative to the enclosing namespace.
  # - `self.name = value.name` then rides that param to `name: String`, and
  #   `foo.name.upcase` makes `run` return `String` — the fixture's `# =>
  #   "JOHN DOE"` comment, checked.
  # - The setter synthesizes an `AfterUser` marker narrowing `user` to a
  #   non-nil `Example2::User`, which is what keeps the bare `attr_reader
  #   user: untyped` from being the last word.
  it "nested-class file via instance receiver matches expected RBS" do
    name = "models/example2"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example2.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Nested classes as their own targets, plus the singleton→instance
  # delegation `Current` uses. Two things this pins down:
  #
  # - `Example3::User`/`Example3::Foo` are emitted as separate targets, not
  #   flattened into `Example3` (which used to claim their `initialize`,
  #   attrs, and `@name`).
  # - `Foo.user = user` types `def self.user=`'s param. `attr_accessor :user`
  #   exposes a SYNTHETIC writer whose param is named after the attr, but the
  #   explicit `def user=(value)` overriding it names the param `value`; when
  #   the synthetic name won, the call-site type was filed under `user` while
  #   the signature said `value`, so the substitution missed and both setters
  #   stayed `untyped`.
  # - `@foo_instance ||= Foo.new` in `def self.foo_instance` is a class-instance
  #   variable → `self.@foo_instance: Foo?`. It shares its name with the instance
  #   `attr_writer :foo_instance`, but that's an INSTANCE attr; only a singleton
  #   attr would suppress the `self.@foo_instance` slot (felixefelip/rbs_infer#86).
  it "nested-class file matches expected RBS (targets + setter param names)" do
    name = "models/example3"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example3.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  it "example4" do
    name = "models/example4"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example4.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Second-hop transitive gap: `run` establishes `Foo.name` then calls
  # `Bar#foo_name` (1st hop — narrows, like example4), which calls
  # `Bar#deep_foo_name` (2nd hop — should narrow but doesn't, since the
  # method-entry fact isn't seeded into `foo_name`'s body to reach its callee).
  # The `deep_foo_name` read is a baselined error until a call-graph fixpoint
  # lands (the piece that also unlocks view -> partial rendering).
  it "example5" do
    name = "models/example5"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example5.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Branch-sensitive flow-extraction gap ("peça (a)"): `run` establishes
  # `Foo.name`, then calls `Bar#greet` from the `else` branch of an `if/else`.
  # The fork's flow extractor walks only the `then` clause, so the else-branch
  # call is never visited and `greet` never gets the entry fact — its read is a
  # baselined error until the extractor descends into every branch. Same shape
  # as `render :new` in the `else` of `if @post.save` (rbs_infer#104).
  it "example6" do
    name = "models/example6"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example6.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Argument-sensitive-facts gap ("peça (3)"): a shared `Dispatcher#show(which)`
  # is called with `:name` where `Foo.name` is established and with `:age` where
  # `Age.value` is established. `show`'s entry facts are the meet over both
  # sites, so both facts drop and both `case` branches error. Closing it needs
  # entry facts partitioned by the literal argument — what a single shared
  # `render`/dispatcher needs to stay precise instead of the whole-app meet.
  it "example7" do
    name = "models/example7"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example7.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # IVAR-ARGUMENT RESOLUTION (unblocks felixefelip/rbs_infer#109).
  # `Example11::Partial#initialize` infers `(post: Example11::Post)` from a call
  # site that passes `@post`, whose type `Example11::View`'s generated RBS
  # declares one class above.
  #
  # Guards two things that were both wrong: an ivar assigned from a PARAMETER is
  # now resolvable at a call site (the syntactic collector only recorded
  # `@x = Foo.new`), and it resolves against the LEXICALLY ENCLOSING class — here
  # `Example11::View`, not the file's top-level `Example11`, which declares no
  # `@post`.
  #
  # Not baselined in steep: `untyped` absorbs every call, so this never errored
  # there. The generated RBS is the only place it shows.
  it "example11" do
    name = "models/example11"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example11.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # IVAR partitions by literal argument (felixefelip/steep#91). `run_name` and
  # `run_age` each establish a DIFFERENT ivar before dispatching, so the
  # whole-method meet proves neither and only the per-literal partition keeps each
  # branch readable. The return type is the give-away: it resolves rather than
  # collapsing to `untyped`, which is what the branch reads failing would produce.
  it "example8" do
    name = "models/example8"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example8.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # `if`/`elsif` consumption of the same partitions (felixefelip/steep#90).
  # Byte-for-byte example7's dispatcher with `case/when` swapped for
  # `if <param> == <literal>`, which isolates the consumer to that one variable.
  it "example9" do
    name = "models/example9"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example9.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # CONST-WRITE RHS (felixefelip/steep#131). `Const.attr = <rhs>` classifies as a
  # write and the RHS is walked for calls first, so a callee reached only from
  # there — `Bar.new.greet` — still receives the facts established above it. What
  # the snapshot pins is the whole chain that follows: `greet` types as `String`
  # rather than erroring, so the write carries a `String` and `run` returns one.
  it "example10" do
    name = "models/example10"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example10.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # SECOND-HOP argument facts (felixefelip/steep#95). example8 with one hop
  # inserted between the establishing write and the dispatch; the fix seeds each
  # flow with its owner's entry facts so the fact survives the hop.
  it "example12" do
    name = "models/example12"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example12.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Halting-guard grammar (felixefelip/steep#105). What the fixture DEMONSTRATES is
  # a steep behavior, pinned by spec/expectations/steep_baseline.txt; this snapshot
  # pins the premise instead. Every gap there shows up as a nil-deref error, which
  # only happens while `Example13Registry.user` is nilable — if inference ever made
  # that reader non-nil the ten baseline entries would vanish and read as ten gaps
  # closed. Here the nilability is explicit, so the two failures can't be confused.
  it "example13" do
    name = "models/example13"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example13.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Example18 with the one change that keeps the real Rails chain open: the halt
  # lands on an object passed as an ARGUMENT (felixefelip/steep#126). What it
  # pins here is that the block half still works across that same boundary —
  # `fetch_token` keeps its required, `String`-shaped block — so a reader can
  # see that what fails is the halt, not the block.
  it "example19" do
    name = "models/example19"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example19.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Example19 with the one thing left between here and the real chain: the call
  # carrying the block sits two conditionals deep, and the inner alternative is
  # the halt — Fizzy's `authenticate_by_bearer_token`. The rule that turns "the
  # block established X" into a fact about the method reads the method's VALUE
  # and unwraps a single one-armed `if`, so it sees nothing here. What the
  # snapshot pins is that everything else still holds: the block keeps its
  # required, `String`-shaped signature, so a reader can tell the nesting is
  # what fails.
  # felixefelip/rbs_infer#168. A parameter typed as the RECEIVER of the
  # expression assigned to it: `Registry.holder = ticket.holder` typed `holder=`
  # as taking a `Ticket?`, because the caller-side map was keyed by `line:column`
  # and a receiver starts where its call does. Fizzy's `Current#identity=` is the
  # same shape, and from there `Current.identity` was a `Session` for the whole
  # app. Keyed by the whole range the receiver stops answering, and with
  # `resolve_all` no longer recording `untyped` over an RBS answer the structural
  # chain fills the slot: `Example21::Holder`, what the source says.
  it "example21" do
    name = "models/example21"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example21.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # A nested module beside a nested class, in a body that declares nothing else.
  # `TargetDiscovery` dropped `Example22` as a pure namespace, and with it the
  # only block `Foo` is ever written into — the file emitted `Example22::Bar`
  # alone, so `Bar.bazingado`'s `super` had no `extend`ed module to reach.
  # Neither half shows it on its own: drop `Bar` and nothing in the file is a
  # target, so the single-target path lands on `Example22` anyway.
  it "example22" do
    name = "models/example22"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example22.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # The same shape with the nested module reached by `extend` from a nested
  # MODULE as well as from a nested class, which is what `MixinIndex#extenders_of`
  # answers and what makes `bazinga`'s parameter a real type instead of `untyped`.
  # It also pins the formatting of a nested module — the blank between siblings and
  # between a module's mixins and its methods, which nothing else in the suite covers
  # because every other nested module is a single group.
  #
  # And it pins the two-homonyms-in-one-target case (felixefelip/rbs_infer#215):
  # `Foo#bazingado` and `Baz.bazingado` are two methods of one name inside one emitted
  # block, the call site reaches the singleton, and only the singleton's line moves.
  it "example23" do
    name = "models/example23"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example23.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # The same shape in a second namespace, with the same method names. The
  # invoker-self narrowing gathers call sites by NAME across the corpus, so each of these
  # two files shows up in the other's observations; read as unplaceable callers, they
  # blanked each other's narrowing (felixefelip/rbs_infer#227). Both snapshots are pinned
  # so the poisoning cannot come back from either side.
  it "example24" do
    name = "models/example24"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example24.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  it "example25" do
    name = "models/example25"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example25.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # The two paths crossed: `bazinga` pairs a different `module_included` with a different
  # `self` at each of its two call sites, and its receiver's branches reach two different
  # methods. Read one parameter at a time the pairing is lost and `BazOther.bazingado`
  # gets a `base_foo` its own body cannot call (felixefelip/rbs_infer#231).
  it "example26" do
    name = "models/example26"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example26.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # `bazingado` stores its block and `bazinga` later replays it through
  # `class_eval`. The stored proc may be nil, but a bare `^() -> Symbol?` makes
  # the PROC'S RETURN optional instead of the proc itself. This snapshot pins
  # the parens required for `(^() -> Symbol)?` (felixefelip/rbs_infer#237).
  it "example28" do
    name = "models/example28"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example28.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  it "example20" do
    name = "models/example20"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example20.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Blocks, whose signature is decided by the body rather than the parameter
  # list: required or not (#147), the parameter types read off the sites that
  # use it (#148), and — for a body that only forwards — the callee's own
  # requirement (#149). The three readings sit side by side in one class
  # precisely because a fix for any of them can break the others.
  # The authentication chain with the establishment inside a BLOCK — the gap
  # felixefelip/rbs_infer#144 is about, and the fixture stage 3 will be built
  # against. What it pins here is the premise: the framework pair carries a
  # required, `String`-shaped block, and `Registry.user` is nilable, so the
  # deref in `show` is a type error for ONE reason. The facts themselves live in
  # `.steep_postconditions.yml`, and the error in the steep baseline.
  it "example18" do
    name = "models/example18"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example18.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  it "example17" do
    name = "models/example17"
    rbs = RbsInfer::Analyzer.new(
      target_file: "app/models/example17.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # The RBS the analyzer derives FROM the runtime pseudo-code, snapshotted next to
  # the pseudo-code itself. The two together localize a regression: the `.rb`
  # changed => generator bug; identical `.rb` with a different `.rbs` => inference
  # pipeline bug.
  #
  # These are the whole point of the view reformulation — the view's ivars and the
  # partial's locals are DERIVED from the render call sites rather than computed by
  # a generator, so a drift in the chain
  # `action -> view ivar -> partial local` shows up here first.
  #
  # `source_files` has to span `app/` AND `sig/`, matching how the CLI is invoked
  # (`rbs_infer app/ sig/`): the call sites that type a view live in the controller
  # runtime under `sig/`, not in `app/`. The `.erb` glob matters for the same reason —
  # a view's own `render partial:` call site lives in the TEMPLATE, so without it the
  # snapshot showed `render: (?untyped target, ...)` and was blind to the second half
  # of the very chain it exists to guard.
  describe "runtime pseudo-code RBS" do
    let(:source_files) { Dir["app/**/*.rb"] + Dir["app/**/*.erb"] + Dir["sig/**/*.rb"] }

    def assert_runtime_rbs(dir)
      pseudo_code = Dir["sig/generated/#{dir}/**/*.rb"].sort
      expect(pseudo_code).not_to be_empty, "no pseudo-code found under sig/generated/#{dir}"

      aggregate_failures do
        pseudo_code.each do |path|
          relative = path.sub("sig/generated/#{dir}/", "").sub(/\.rb\z/, "")
          rbs = RbsInfer::Analyzer.new(target_file: path, source_files: source_files).generate_rbs

          expectation = expectations_dir.join("#{dir}/#{relative}.rbs")
          if ENV["UPDATE_EXPECTATIONS"]
            expectation.dirname.mkpath
            expectation.write(rbs)
          end

          expect(rbs.chomp).to eq(expectation.read.chomp), "#{dir}/#{relative}"
        end
      end
    end

    it "controller runtime" do
      assert_runtime_rbs("steep_controller_runtime")
    end

    # The transcription's own pseudo-code, which nothing else compared with a
    # fresh generation: `assert_runtime_rbs` derives the `.rbs` FROM the
    # checked-in `.rb`, so a stale body yields a consistent, stale signature and
    # the suite stays green. The Devise generator has had this guard all along
    # (felixefelip/rbs_infer#160).
    it "emits the transcription checked into the dummy" do
      # Inside the example, not at the top: the seeds are reflected off real
      # constants, so the framework has to be loaded — and loading it from a
      # file's top level is what made `transcribe_framework:` a parameter rather
      # than a detection in the first place (felixefelip/rbs_infer#146).
      require "action_controller"
      require "rbs_infer/extensions/rails/controllers/framework_source_transcriber"

      files = RbsInfer::Extensions::Rails::Controllers::FrameworkSourceTranscriber.new.build
      expect(files).not_to be_empty

      aggregate_failures do
        files.each do |file|
          checked_in = Pathname.new("sig/generated/steep_controller_runtime").join(file[:filename])
          expect(file[:source]).to eq(checked_in.read),
                                   "#{checked_in} is stale — re-run `rake rbs_infer:controller_runtime:all`"
        end
      end
    end

    it "view runtime" do
      assert_runtime_rbs("steep_actionview_runtime")
    end

    it "ActiveRecord runtime" do
      assert_runtime_rbs("steep_ar_runtime")
    end

    # The Devise helpers' RBS is now INFERRED from their pseudo-code — this snapshot is
    # where `current_account: () -> (Account & Account::Validated)?` shows up without the
    # generator ever having written a type.
    it "Devise runtime" do
      assert_runtime_rbs("steep_devise_runtime")
    end

    # The only runtime sidecar that had no snapshot, and the one that most needed
    # it: `Current`'s attributes are typed entirely from call sites in other
    # files, so its RBS moves whenever that inference moves. Two things went
    # unseen for want of this — a `-> nil` on `self.with` that was the previous
    # generation's own output feeding itself (felixefelip/rbs_infer#156), and an
    # `author_name: String?` that no source could justify. Both would have read
    # as a diff here.
    it "Current runtime" do
      assert_runtime_rbs("steep_current_runtime")
    end
  end

  # Class-instance variables (felixefelip/rbs_infer#86). A `@x` written in a
  # singleton method (`def self.x`, `class << self`) or directly in the class
  # body is a class-instance variable — RBS declares it `self.@x`, a slot
  # distinct from the instance `@x`. What this pins down:
  #
  # - `@instance_ivar` (written in `initialize`) stays `@instance_ivar: String`.
  # - `@singleton_ivar` (`def self.build`) and `@label` (`class << self`) become
  #   `self.@...: String?` — nilable, since no class-body write initializes them.
  # - `@config` is written both in the class body (`@config = "default"`) and in
  #   `def self.configure`; the class-body write is the definite initialization a
  #   class-instance variable can have, so it's `self.@config: String` (non-nil)
  #   and does NOT also leak out as an instance `@config`.
  it "class-instance variables are emitted as self.@x, not instance ivars" do
    name = "models/singleton_ivar_probe"
    rbs = RbsInfer::Analyzer.new(
      target_class: "SingletonIvarProbe",
      target_file: "app/models/singleton_ivar_probe.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Multi-target file (felixefelip/rbs_infer#38): no target_class is
  # passed, so the analyzer discovers and emits every type the file
  # reopens — the `on_load` blocks (expanded to `ActiveStorage::Blob` /
  # `Attachment`), the `to_prepare` module, and the four
  # `Receiver.include ActiveStorage::Authorize` controllers.
  it "multi-target rails_ext file matches expected RBS" do
    name = "lib/rails_ext/active_storage_authorization"
    rbs = RbsInfer::Analyzer.new(
      target_file: "#{name}.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
  end

  # Reopening a generic core class via `Receiver.include` must repeat its
  # exact type parameters, or RBS rejects the file with
  # GenericParameterMismatchError (felixefelip/rbs_infer#38).
  it "generic-class reopen carries the class's type parameters" do
    require "tmpdir"
    name = "lib/rails_ext/array_conversions"
    rbs = RbsInfer::Analyzer.new(
      target_file: "#{name}.rb",
      source_files: source_files
    ).generate_rbs

    if ENV["UPDATE_EXPECTATIONS"]
      path = expectations_dir.join("#{name}.rbs")
      path.dirname.mkpath
      path.write(rbs)
    end

    expect(rbs.chomp).to eq(expected_rbs(name).chomp)
    expect(rbs).to include("class Array[unchecked out Elem]")

    # The reopen must load cleanly alongside core RBS (the original crash
    # was a GenericParameterMismatchError raised while building ::Array).
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "gen.rbs"), rbs)
      loader = RBS::EnvironmentLoader.new
      loader.add(path: Pathname(dir))
      env = RBS::Environment.from_loader(loader).resolve_type_names
      defn = RBS::DefinitionBuilder.new(env: env)
                                   .build_instance(RBS::TypeName.parse("::Array").absolute!)
      expect(defn.methods).to have_key(:to_choice_sentence)
    end
  end

  it "PostsController matches expected RBS" do
    assert_snapshot("controllers/posts_controller", target_class: "PostsController", target_file: "app/controllers/posts_controller.rb")
  end

  it "UsersController matches expected RBS" do
    assert_snapshot("controllers/users_controller", target_class: "UsersController", target_file: "app/controllers/users_controller.rb")
  end

  it "Users::AvatarsController matches expected RBS" do
    assert_snapshot("controllers/users/avatars_controller", target_class: "Users::AvatarsController", target_file: "app/controllers/users/avatars_controller.rb")
  end

  # The Devise consumer. `@account = current_account` gets its type from the generated
  # `DeviseScopedHelpers` — nothing in the source names `Account` — so this snapshot is
  # what would catch the scoped helpers silently reverting to `untyped`.
  it "DashboardController matches expected RBS" do
    assert_snapshot("controllers/dashboard_controller", target_class: "DashboardController", target_file: "app/controllers/dashboard_controller.rb")
  end

  it "AvatarUploader matches expected RBS" do
    assert_snapshot("uploaders/avatar_uploader", target_class: "AvatarUploader", target_file: "app/uploaders/avatar_uploader.rb")
  end

  describe "CarrierWave mount_uploader generator" do
    require "rbs_infer/extensions/carrierwave/generator"
    require "tmpdir"
    require "fileutils"

    it "rewrites User accessors and strips conflicting rbs_rails column defs" do
      Dir.mktmpdir do |tmpdir|
        rbs_rails_copy = File.join(tmpdir, "rbs_rails")
        FileUtils.cp_r("sig/rbs_rails", rbs_rails_copy)

        generator = RbsInfer::Extensions::CarrierWave::Generator.new(
          app_dir: Dir.pwd,
          output_dir: tmpdir,
          rbs_rails_dir: rbs_rails_copy
        )
        generator.generate_all

        rbs = File.read(File.join(tmpdir, "app/models/user.rbs"))

        if ENV["UPDATE_EXPECTATIONS"]
          path = expectations_dir.join("carrierwave/user.rbs")
          FileUtils.mkdir_p(path.dirname)
          path.write(rbs)
        end

        expect(rbs.chomp).to eq(expected_rbs("carrierwave/user").chomp)

        stripped = File.read(File.join(rbs_rails_copy, "app/models/user.rbs"))
        expect(stripped).not_to match(/^\s+def avatar:/)
        expect(stripped).not_to match(/^\s+def avatar=:/)
        expect(stripped).not_to match(/^\s+def avatar\?:/)
        expect(stripped).to match(/^\s+def avatar_changed\?:/)
        expect(stripped).to match(/^\s+def avatar_before_type_cast:/)
      end
    end

    it "skips models without mount_uploader" do
      Dir.mktmpdir do |tmpdir|
        rbs_rails_copy = File.join(tmpdir, "rbs_rails")
        FileUtils.cp_r("sig/rbs_rails", rbs_rails_copy)

        generator = RbsInfer::Extensions::CarrierWave::Generator.new(
          app_dir: Dir.pwd,
          output_dir: tmpdir,
          rbs_rails_dir: rbs_rails_copy
        )
        generator.generate_all

        expect(File.exist?(File.join(tmpdir, "app/models/post.rbs"))).to be false
        expect(File.exist?(File.join(tmpdir, "app/models/comment.rbs"))).to be false
      end
    end
  end

  describe "Devise scoped helpers generator" do
    require "rbs_infer/extensions/devise/generator"
    require "tmpdir"

    # The unit specs drive this generator with synthetic fixtures. Here it runs against the
    # real dummy, so what it reads is the actual `devise_for :accounts` in config/routes.rb.
    # The emitted pseudo-code is snapshotted as the dummy's own file (it IS the checked-in
    # sig/generated/steep_devise_runtime/), which is also what `steep check` consumes.
    it "emits the pseudo-code checked into the dummy" do
      Dir.mktmpdir do |tmpdir|
        generator = RbsInfer::Extensions::Devise::Generator.new(app_dir: Dir.pwd, output_dir: tmpdir)
        scopes = generator.generate_all

        expect(scopes).to eq([{ scope: "account", class_name: "Account" }])

        source = File.read(File.join(tmpdir, RbsInfer::Extensions::Devise::Generator::FILENAME))
        checked_in = Pathname.new(RbsInfer::Extensions::Devise::Generator::SIDECAR_DIR)
                             .join(RbsInfer::Extensions::Devise::Generator::FILENAME)

        expect(source).to eq(checked_in.read),
                          "sig/generated/steep_devise_runtime/ is stale — re-run `rake rbs_infer:devise:all`"
      end
    end

    # The whole chain, with nothing pre-derived anywhere in it.
    # `DashboardController#set_current_account` writes `Current.account = current_account`
    # under the Devise guard, and every link is now inferred:
    #
    #   1. `current_account` resolves from DashboardController — the helpers are included
    #      into ActionController::Base by the Devise sidecar, a reopening the resolver
    #      unions (felixefelip/rbs_infer#124);
    #   2. the attribute is typed from that call site, so `Current.account=` establishes
    #      the const;
    #   3. `set_current_account` cannot halt, so it establishes `Current.account`
    #      unconditionally (felixefelip/steep#100) and the fact reaches the action AND the
    #      view it renders.
    #
    # Link 3 is what `Rails::CurrentAttributesCallbacksGenerator` used to assert by hand,
    # and #125 removed it to leave the gap in the steep baseline. That entry is gone now,
    # which is what makes this the regression guard for all three at once.
    #
    # Asserted on the FACTS, not on `steep check` being clean: while the attribute was
    # still `untyped` the same read type-checked vacuously, and that read a clean run as
    # proof once already.
    it "carries a populated Current from the handler into the action and its view" do
      current_rbs = Pathname.new("sig/rbs_infer/sig/generated/steep_current_runtime/current.rbs").read
      postconditions = YAML.safe_load(Pathname.new("sig/generated/.steep_postconditions.yml").read)
      account_type = "(::Account & ::Account::Validated)"

      # Links 1 + 2.
      expect(current_rbs).to include("def self.account: () -> (Account & Account::Validated)?")
      expect(postconditions["postconditions"]).to include(
        a_hash_including("class" => "Current", "method" => "account=",
                         "unconditional" => a_hash_including(
                           "establishes_consts" => { "account" => account_type }
                         ))
      )

      # Link 3: the handler establishes it, with no gate to key it on...
      expect(postconditions["postconditions"]).to include(
        a_hash_including("class" => "DashboardController", "method" => "set_current_account",
                         "unconditional" => { "consts" => { "Current.account" => account_type } })
      )

      # ...and it lands at the action, at the render dispatch, and in the template body —
      # the last one being why `Current.account.label` in dashboard/show.html.erb needs no
      # nil check.
      carriers = (postconditions["method_entry_facts"] || [])
                   .select { |e| (e["consts"] || {})["Current.account"] == account_type }
                   .map { |e| "#{e["class"]}##{e["method"]}" }
      expect(carriers).to include("DashboardController#show", "DashboardController#render",
                                  "ERBDashboardShow#__rbs_infer__body")
    end
  end

  it "PostPublisher service matches expected RBS" do
    assert_snapshot("services/post_publisher", target_class: "PostPublisher", target_file: "app/services/post_publisher.rb")
  end

  it "ProfileFormatter service matches expected RBS" do
    assert_snapshot("services/profile_formatter", target_class: "ProfileFormatter", target_file: "app/services/profile_formatter.rb")
  end

  # felixefelip/rbs_infer#175. Constructed only from inside a concern, with
  # `self` — so the parameter is whoever includes the module, which needs the
  # mixin graph. Two of the paths that walk caller files were not given it and
  # answered `untyped`, and those are the ones that decide an `initialize`
  # parameter. Fizzy's `Card::ActivitySpike::Detector.new(self)` is this shape.
  it "WidgetAuditor takes the includer's type from a concern's `self`" do
    assert_snapshot("services/widget_auditor", target_class: "WidgetAuditor", target_file: "app/services/widget_auditor.rb")
  end

  # felixefelip/rbs_infer#183. `initialize` assigns every ivar on one line
  # (`@user, @post, @expanded = user, post, expanded`), which Prism shapes as a
  # `MultiWriteNode` — the ivar → param link, and the definite-initialization
  # rule behind it, both have to read that shape or the attrs come out
  # `untyped`/`T?` while the params are fully typed. Fizzy's `User::Filtering`.
  it "PostFiltering types attrs assigned by a single multiple assignment" do
    assert_snapshot("services/post_filtering", target_class: "PostFiltering", target_file: "app/services/post_filtering.rb")
  end

  it "ApplicationJob base class matches expected RBS" do
    assert_snapshot("jobs/application_job", target_class: "ApplicationJob", target_file: "app/jobs/application_job.rb")
  end

  it "ProfileFormatterJob matches expected RBS" do
    assert_snapshot("jobs/profile_formatter_job", target_class: "ProfileFormatterJob", target_file: "app/jobs/profile_formatter_job.rb")
  end

  it "EmailNotifier service matches expected RBS" do
    assert_snapshot("services/email_notifier", target_class: "EmailNotifier", target_file: "app/services/email_notifier.rb")
  end

  it "TagDestroy service matches expected RBS" do
    assert_snapshot("services/tag_destroy", target_class: "TagDestroy", target_file: "app/services/tag_destroy.rb")
  end

  it "ParseXml service matches expected RBS" do
    assert_snapshot("services/parse_xml", target_class: "ParseXml", target_file: "app/services/parse_xml.rb")
  end

  # felixefelip/rbs_infer#64: `action` is called with `String` (intra-class)
  # and `Symbol` (via EventReporter), so it should infer `(String | Symbol)`.
  it "EventTracker service unions param types across call-sites" do
    assert_snapshot("services/event_tracker", target_class: "EventTracker", target_file: "app/services/event_tracker.rb")
  end

  # felixefelip/rbs_infer#64: `track_event` (in a concern) is called *bare*
  # from the host's sibling concerns (Widget::Publishable/Closeable, which
  # don't name Eventable), with `String` and `Symbol` → `action: (String | Symbol)`.
  it "Eventable concern unions bare-call param types from sibling concerns" do
    assert_snapshot("models/eventable", target_class: "Eventable", target_file: "app/models/eventable.rb")
  end

  it "Post::Taggable concern matches expected RBS" do
    assert_snapshot("models/post/taggable", target_class: "Post::Taggable", target_file: "app/models/post/taggable.rb")
  end

  it "Post::Notifiable concern matches expected RBS" do
    assert_snapshot("models/post/notifiable", target_class: "Post::Notifiable", target_file: "app/models/post/notifiable.rb")
  end

  it "User::Recoverable concern matches expected RBS" do
    assert_snapshot("models/user/recoverable", target_class: "User::Recoverable", target_file: "app/models/user/recoverable.rb")
  end

  # felixefelip/rbs_infer#139. `has_many :notifications` is declared ONLY in this
  # concern's `included do`, so every method below derefs an association the
  # AR-runtime generator can emit only by reading the concern and attributing it
  # to `User`. Before the fix the getter did not exist and all four came out
  # `untyped`; the snapshot is where that regression would resurface.
  it "User::Notifiable concern (has_many from a concern) matches expected RBS" do
    assert_snapshot("models/user/notifiable", target_class: "User::Notifiable", target_file: "app/models/user/notifiable.rb")
  end

  it "User::Displayable concern matches expected RBS" do
    assert_snapshot("models/user/displayable", target_class: "User::Displayable", target_file: "app/models/user/displayable.rb")
  end

  it "Test::Filtrable concern matches expected RBS" do
    assert_snapshot("models/concerns/test/filtrable", target_class: "Test::Filtrable", target_file: "app/models/concerns/test/filtrable.rb")
  end

  it "FilterConfiguration controller concern matches expected RBS" do
    assert_snapshot("controllers/concerns/filter_configuration", target_class: "FilterConfiguration", target_file: "app/controllers/concerns/filter_configuration.rb")
  end

  it "ApplicationHelper matches expected RBS" do
    assert_snapshot("helpers/application_helper", target_class: "ApplicationHelper", target_file: "app/helpers/application_helper.rb")
  end

  it "PostsHelper matches expected RBS" do
    assert_snapshot("helpers/posts_helper", target_class: "PostsHelper", target_file: "app/helpers/posts_helper.rb")
  end

  # Regression for the ivar-vs-local name collision, combined with the `?` outer-unwrap in `extract_element_type`. The
  # `post_index_marker` helper is called ONLY from `posts/index.html.erb`
  # inside `@posts.each |post|`, so its parameter must come from the
  # block-element resolution (`Post::ActiveRecord_Relation?` →
  # `Post & Post::Validated`), not from the controller's `@post` ivar
  # (which has a wide nilable union and would pollute the local lookup
  # without the namespace separation).
  it "narrows helper param via block-param resolution (ivar/local name-collision regression)" do
    rbs = generate_rbs(
      target_class: "PostsHelper",
      target_file: "app/helpers/posts_helper.rb",
    )

    expect(rbs).to include("def post_index_marker: ((Post & Post::Validated) post)")
  end

  it "ApplicationController rails_custom matches expected RBS" do
    require "rbs_infer/extensions/rails/custom_generator"
    require "tmpdir"
    Dir.mktmpdir do |tmpdir|
      generator = RbsInfer::Extensions::Rails::CustomGenerator.new(
        output_dir: tmpdir,
        app_dir: Dir.pwd,
        source_files: source_files
      )
      generator.generate_all
      rbs = File.read(File.join(tmpdir, "application_controller.rbs"))

      if ENV["UPDATE_EXPECTATIONS"]
        expectations_dir.join("controllers/application_controller.rbs").write(rbs)
      end

      expect(rbs.chomp).to eq(expected_rbs("controllers/application_controller").chomp)
    end
  end

  it "ActionViewContext rails_custom matches expected RBS" do
    require "rbs_infer/extensions/rails/custom_generator"
    require "tmpdir"
    Dir.mktmpdir do |tmpdir|
      generator = RbsInfer::Extensions::Rails::CustomGenerator.new(
        output_dir: tmpdir,
        app_dir: Dir.pwd,
        source_files: source_files
      )
      generator.generate_all
      rbs = File.read(File.join(tmpdir, "action_view_context.rbs"))

      if ENV["UPDATE_EXPECTATIONS"]
        expectations_dir.join("rails_custom_action_view_context.rbs").write(rbs)
      end

      expect(rbs.chomp).to eq(expected_rbs("rails_custom_action_view_context").chomp)
    end
  end

end
