# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/current_attributes_runtime_generator"

RSpec.describe "Rails dummy app integration", :dummy_app do
  let(:source_files) { Dir["app/**/*.rb"] }
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

  it "Comment model matches expected RBS" do
    assert_snapshot("models/comment", target_class: "Comment", target_file: "app/models/comment.rb")
  end

  it "Tag model matches expected RBS" do
    assert_snapshot("models/tag", target_class: "Tag", target_file: "app/models/tag.rb")
  end

  it "PostTag model matches expected RBS" do
    assert_snapshot("models/post_tag", target_class: "PostTag", target_file: "app/models/post_tag.rb")
  end

  it "Current (CurrentAttributes) matches expected RBS" do
    assert_snapshot("models/current", target_class: "Current", target_file: "app/models/current.rb")
  end

  it "Palette (class constants) matches expected RBS" do
    assert_snapshot("models/palette", target_class: "Palette", target_file: "app/models/palette.rb")
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

  it "PostPublisher service matches expected RBS" do
    assert_snapshot("services/post_publisher", target_class: "PostPublisher", target_file: "app/services/post_publisher.rb")
  end

  it "ProfileFormatter service matches expected RBS" do
    assert_snapshot("services/profile_formatter", target_class: "ProfileFormatter", target_file: "app/services/profile_formatter.rb")
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
    require "rbs_infer/extensions/rails/erb_caller_resolver"
    erb_resolver = RbsInfer::Extensions::Rails::ErbCallerResolver.new(app_dir: Dir.pwd, source_files: source_files)
    assert_snapshot("helpers/application_helper", target_class: "ApplicationHelper", target_file: "app/helpers/application_helper.rb", extra_caller_sources: erb_resolver)
  end

  it "PostsHelper matches expected RBS" do
    require "rbs_infer/extensions/rails/erb_caller_resolver"
    erb_resolver = RbsInfer::Extensions::Rails::ErbCallerResolver.new(app_dir: Dir.pwd, source_files: source_files)
    assert_snapshot("helpers/posts_helper", target_class: "PostsHelper", target_file: "app/helpers/posts_helper.rb", extra_caller_sources: erb_resolver)
  end

  # Regression for the ivar-vs-local name collision in `ErbCallerResolver`
  # combined with the `?` outer-unwrap in `extract_element_type`. The
  # `post_index_marker` helper is called ONLY from `posts/index.html.erb`
  # inside `@posts.each |post|`, so its parameter must come from the
  # block-element resolution (`Post::ActiveRecord_Relation?` →
  # `Post & Post::Validated`), not from the controller's `@post` ivar
  # (which has a wide nilable union and would pollute the local lookup
  # without the namespace separation).
  it "narrows helper param via block-param resolution (ivar/local name-collision regression)" do
    require "rbs_infer/extensions/rails/erb_caller_resolver"
    erb_resolver = RbsInfer::Extensions::Rails::ErbCallerResolver.new(app_dir: Dir.pwd, source_files: source_files)
    rbs = generate_rbs(
      target_class: "PostsHelper",
      target_file: "app/helpers/posts_helper.rb",
      extra_caller_sources: erb_resolver
    )

    expect(rbs).to include("def post_index_marker: (Post & Post::Validated post)")
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

  describe "ERB convention generator" do
    let(:erb_generator) do
      require "rbs_infer/extensions/rails/erb_convention_generator"
      @erb_tmpdir = Dir.mktmpdir
      RbsInfer::Extensions::Rails::ErbConventionGenerator.new(
        app_dir: Dir.pwd,
        output_dir: @erb_tmpdir,
        source_files: source_files
      )
    end

    after { FileUtils.remove_entry(@erb_tmpdir) if @erb_tmpdir }

    before { erb_generator.generate_all }

    def assert_erb_snapshot(output_file:)
      rbs = File.read(File.join(@erb_tmpdir, output_file))
      snapshot_name = output_file.delete_prefix("app/").delete_suffix(".rbs")

      if ENV["UPDATE_EXPECTATIONS"]
        path = expectations_dir.join("#{snapshot_name}.rbs")
        FileUtils.mkdir_p(path.dirname)
        path.write(rbs)
      end

      expect(rbs.chomp).to eq(expected_rbs(snapshot_name).chomp)
    end

    it "ERBPostsShow matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/show.rbs")
    end

    it "ERBPostsIndex matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/index.rbs")
    end

    it "ERBPostsNew matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/new.rbs")
    end

    it "ERBPostsEdit matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/edit.rbs")
    end

    # Regression for the cross-action rendering tracking
    # (felixefelip/rbs_infer#6). The controller's `update` action does
    # `render :edit` on validation failure, so `edit.html.erb` is
    # rendered by two actions. Per-action narrowing would type `@post`
    # by `edit`'s writers alone (`set_post` via `before_action` →
    # `Post & Validated`) and miss `update`'s falsy-branch
    # contribution. The wide fallback uses the controller's declared
    # union, preserving soundness across both rendering paths.
    it "widens @post in edit.rbs when update renders :edit (cross-action regression)" do
      output_dir = @erb_tmpdir
      rbs = File.read(File.join(output_dir, "app/views/posts/edit.rbs"))
      expect(rbs).to include("@post: Post | (Post & Post::Validated)")
    end

    it "widens @post in new.rbs when create renders :new (cross-action regression)" do
      output_dir = @erb_tmpdir
      rbs = File.read(File.join(output_dir, "app/views/posts/new.rbs"))
      expect(rbs).to include("@post: Post | (Post & Post::Validated)")
    end

    it "keeps single-renderer narrowing on show.rbs (not rendered by any other action)" do
      output_dir = @erb_tmpdir
      rbs = File.read(File.join(output_dir, "app/views/posts/show.rbs"))
      # `show.html.erb` is only rendered by `show` action; per-action
      # narrowing applies → `Post & Validated` (from `set_post`), no
      # wide fallback.
      expect(rbs).to include("@post: (Post & Post::Validated)")
    end

    it "ERBPartialPostsForm matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/_form.rbs")
    end

    it "ERBPartialPostsComment matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/_comment.rbs")
    end

    # _summary is rendered via shorthand: render "posts/summary", post: @post
    # (no `partial:` / `locals:` keys) — verifies shorthand render local inference
    it "ERBPartialPostsSummary matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/posts/_summary.rbs")
    end

    it "shorthand render infers local type without partial:/locals: keys" do
      rbs = File.read(File.join(@erb_tmpdir, "app/views/posts/_summary.rbs"))
      # The per-action narrowing (#4 follow-up) picks the writer that
      # actually runs for `show` — `set_post` via the controller's
      # `before_action`. So `post` resolves to the `Validated` branch,
      # not the wide union. The shorthand inference path is still
      # exercised; just the resulting type is the narrowed one.
      expect(rbs).to include("attr_reader post:")
      expect(rbs).to match(/attr_reader post: \(?Post(?:\s|\)|$)/)
    end

    it "shorthand render does not bleed into explicit partial:/locals: inference" do
      rbs = File.read(File.join(@erb_tmpdir, "app/views/posts/_comment.rbs"))
      expect(rbs).to include("attr_reader comment: Comment")
      expect(rbs).not_to include("post:")
    end

    it "ERBLayoutsApplication matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/layouts/application.rbs")
    end

    it "ERBUsersShow matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/users/show.rbs")
    end

    it "ERBUsersAvatarsEdit matches expected RBS" do
      assert_erb_snapshot(output_file: "app/views/users/avatars/edit.rbs")
    end
  end
end
