# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"
require "rbs_infer/extensions/rails/views/runtime_generator"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Extensions::Rails::Views::RuntimeGenerator do
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

  def build(files)
    in_app(files) { |dir| described_class.new(app_dir: dir).build }
  end

  def source_of(result, filename)
    result.find { |f| f.filename == filename }&.source
  end

  # The body of one method, stripped of indentation, so assertions read as source.
  def method_body(source, name)
    lines = source.lines.map(&:rstrip)
    start = lines.index { |l| l.strip == "def #{name}" || l.strip.start_with?("def #{name}(") }
    return nil unless start

    finish = lines[start..].index { |l| l == "  end" }
    lines[(start + 1)...(start + finish)].map { |l| l.sub(/\A    /, "") }.join("\n")
  end

  describe "the view class" do
    it "takes the template's ivars as keyword arguments and assigns them" do
      # The view declares what it needs; the controller-runtime render override then
      # passes exactly these. Types are never written here — they come from that call site.
      result = build("app/views/posts/edit.html.erb" => "<h1><%= @post.title %></h1>\n")

      expect(method_body(source_of(result, "posts/edit.rb"), "initialize")).to eq("@post = post")
      expect(source_of(result, "posts/edit.rb")).to include("def initialize(post:)")
    end

    it "names the class by the ERB convention and includes the view context" do
      result = build("app/views/posts/edit.html.erb" => "<%= @post %>\n")

      expect(source_of(result, "posts/edit.rb")).to include("class ERBPostsEdit")
      expect(source_of(result, "posts/edit.rb")).to include("include ActionViewContext")
    end

    it "includes the controller's helper module when the app defines one" do
      result = build(
        "app/views/posts/edit.html.erb" => "<%= @post %>\n",
        "app/helpers/posts_helper.rb" => "module PostsHelper\nend\n"
      )

      expect(source_of(result, "posts/edit.rb")).to include("include PostsHelper")
    end

    it "omits the helper include when the app has no matching helper" do
      result = build("app/views/posts/edit.html.erb" => "<%= @post %>\n")

      expect(source_of(result, "posts/edit.rb")).not_to include("include PostsHelper")
    end

    it "declares the compiled-body method the ERB template maps onto" do
      # felixefelip/steep#85: the template is checked with `@type self_method:` naming
      # this method, so it has to exist for the body to attach to the class.
      result = build("app/views/posts/edit.html.erb" => "<%= @post %>\n")

      expect(source_of(result, "posts/edit.rb")).to include("def __rbs_infer__body")
    end

    it "emits no initializer for a template that reads no ivars" do
      result = build("app/views/layouts/application.html.erb" => "<%= yield %>\n")

      expect(source_of(result, "layouts/application.rb")).not_to include("def initialize")
      expect(source_of(result, "layouts/application.rb")).to include("class ERBLayoutsApplication")
    end
  end

  describe "the partial class" do
    it "takes its locals as keywords and exposes them as private readers" do
      # A partial reads its locals as bare names, so they need readers — unlike a view,
      # whose ivars are read as `@post`.
      result = build(
        "app/views/posts/_form.html.erb" => "<%= post.title %>\n",
        "app/views/posts/edit.html.erb" => "<%= render partial: \"posts/form\", locals: { post: @post } %>\n"
      )

      source = source_of(result, "posts/_form.rb")
      expect(source).to include("def initialize(post:)")
      expect(source).to include("private")
      expect(source).to include("attr_reader :post")
    end

    it "collects local names from every call site that renders it" do
      result = build(
        "app/views/posts/_form.html.erb" => "<%= post %>\n",
        "app/views/posts/edit.html.erb" => "<%= render partial: \"posts/form\", locals: { post: @post } %>\n",
        "app/views/posts/new.html.erb" => "<%= render partial: \"posts/form\", locals: { post: @post, mode: @mode } %>\n"
      )

      expect(source_of(result, "posts/_form.rb")).to include("def initialize(mode:, post:)")
    end
  end

  describe "the render method" do
    it "constructs the partial with the locals as written at the call site" do
      # The whole point: this is a real call site, so the analyzer types `post` from
      # `@post` here rather than from a union over every render in the app.
      result = build(
        "app/views/posts/_form.html.erb" => "<%= post %>\n",
        "app/views/posts/edit.html.erb" => "<%= render partial: \"posts/form\", locals: { post: @post } %>\n"
      )

      expect(method_body(source_of(result, "posts/edit.rb"), "render")).to eq(
        "name = target.is_a?(::Hash) ? target[:partial] : target\n" \
        "case name\n" \
        "when \"posts/form\" then ERBPartialPostsForm.new(post: @post).__rbs_infer__body\n" \
        "end\n" \
        "nil"
      )
    end

    it "resolves a partial named relative to the rendering template's directory" do
      result = build(
        "app/views/posts/_form.html.erb" => "<%= post %>\n",
        "app/views/posts/edit.html.erb" => "<%= render partial: \"form\", locals: { post: @post } %>\n"
      )

      # The `when` key is the name AS WRITTEN at the call site (so a shorthand
      # `render "form"` matches it), while the class comes from the resolved path.
      expect(method_body(source_of(result, "posts/edit.rb"), "render")).to eq(
        "name = target.is_a?(::Hash) ? target[:partial] : target\n" \
        "case name\n" \
        "when \"form\" then ERBPartialPostsForm.new(post: @post).__rbs_infer__body\n" \
        "end\n" \
        "nil"
      )
    end

    it "reads the shorthand form where locals are plain keyword arguments" do
      result = build(
        "app/views/posts/_summary.html.erb" => "<%= post %>\n",
        "app/views/posts/show.html.erb" => "<%= render \"posts/summary\", post: @post %>\n"
      )

      expect(method_body(source_of(result, "posts/show.rb"), "render")).to include(
        "when \"posts/summary\" then ERBPartialPostsSummary.new(post: @post).__rbs_infer__body"
      )
    end

    it "reproduces the enclosing iteration so the local gets the element type" do
      # Emitting the loop lets the pipeline derive the element type of `@comments`.
      # The alternative — unwrapping `Array[T]` here — is the hand-rolled inference
      # this generator exists to remove.
      result = build(
        "app/views/posts/_comment.html.erb" => "<%= comment %>\n",
        "app/views/posts/show.html.erb" => <<~ERB
          <% @comments.each do |comment| %>
            <%= render partial: "comment", locals: { comment: comment } %>
          <% end %>
        ERB
      )

      expect(method_body(source_of(result, "posts/show.rb"), "render")).to include(
        "when \"comment\" then @comments.each { |comment| ERBPartialPostsComment.new(comment: comment).__rbs_infer__body }"
      )
    end

    it "models a collection render as the equivalent iteration" do
      # `collection:` renders once per element, binding it to a local named after the
      # partial — so it is the same shape as an explicit `each`.
      result = build(
        "app/views/posts/_comment.html.erb" => "<%= comment %>\n",
        "app/views/posts/show.html.erb" => "<%= render partial: \"comment\", collection: @comments %>\n"
      )

      expect(method_body(source_of(result, "posts/show.rb"), "render")).to include(
        "when \"comment\" then @comments.each { |comment| ERBPartialPostsComment.new(comment: comment).__rbs_infer__body }"
      )
    end

    it "emits one call per render, in template order" do
      result = build(
        "app/views/posts/_comment.html.erb" => "<%= comment %>\n",
        "app/views/posts/_summary.html.erb" => "<%= post %>\n",
        "app/views/posts/show.html.erb" => <<~ERB
          <%= render partial: "comment", locals: { comment: @comment } %>
          <%= render "posts/summary", post: @post %>
        ERB
      )

      expect(method_body(source_of(result, "posts/show.rb"), "render")).to eq(
        "name = target.is_a?(::Hash) ? target[:partial] : target\n" \
        "case name\n" \
        "when \"comment\" then ERBPartialPostsComment.new(comment: @comment).__rbs_infer__body\n" \
        "when \"posts/summary\" then ERBPartialPostsSummary.new(post: @post).__rbs_infer__body\n" \
        "end\n" \
        "nil"
      )
    end

    it "takes the partial name the way ActionView does, from either call form" do
      # The `partial:`/`locals:` form passes a HASH as the first argument, so dispatching on
      # it directly would describe a branch the template can never reach. Modelling the
      # extraction keeps both call forms live.
      result = build(
        "app/views/posts/_form.html.erb" => "<%= post %>\n",
        "app/views/posts/edit.html.erb" => "<%= render partial: \"posts/form\", locals: { post: @post } %>\n"
      )

      source = source_of(result, "posts/edit.rb")
      expect(source).to include("def render(target = nil, *rest)")
      expect(source).to include("case name")
      expect(source).not_to include("args.first")
    end

    it "is omitted for a template that renders nothing" do
      result = build("app/views/posts/edit.html.erb" => "<%= @post %>\n")

      expect(source_of(result, "posts/edit.rb")).not_to include("def render")
    end

    it "skips a render whose partial does not exist" do
      result = build("app/views/posts/edit.html.erb" => "<%= render partial: \"posts/gone\", locals: { post: @post } %>\n")

      expect(source_of(result, "posts/edit.rb")).not_to include("def render")
    end
  end

  describe "#generate" do
    it "writes one file per template and clears a stale sidecar" do
      in_app("app/views/posts/edit.html.erb" => "<%= @post %>\n") do |dir|
        stale = File.join(dir, described_class::SIDECAR_DIR, "posts", "gone.rb")
        FileUtils.mkdir_p(File.dirname(stale))
        File.write(stale, "# stale")

        described_class.new(app_dir: dir).generate

        expect(File).to exist(File.join(dir, described_class::SIDECAR_DIR, "posts", "edit.rb"))
        expect(File).not_to exist(stale)
      end
    end
  end

  describe "dummy snapshot" do
    let(:expectations) { Pathname(DUMMY_APP_ROOT).dirname.join("expectations/steep_actionview_runtime") }

    it "matches the expected pseudo-code for every template" do
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
        written = expectations.glob("**/*.rb").map { |p| p.relative_path_from(expectations).to_s }.sort
        expect(written).to eq(files.map(&:filename).sort)
      end
    end
  end
end
