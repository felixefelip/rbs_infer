# frozen_string_literal: true

require "spec_helper"
require "rbs_infer/extensions/rails/partial_render_graph"
require "tmpdir"
require "fileutils"

RSpec.describe RbsInfer::Extensions::Rails::PartialRenderGraph do
  # Builds a graph over a tmp app whose files are { relative_path => source }.
  def graph(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, src|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, src)
      end
      yield described_class.new(app_dir: dir).build
    end
  end

  it "records a shorthand `render 'doses'` edge resolved against the caller dir" do
    graph(
      "app/views/caderneta/index.html.erb" => "<%= render 'doses', vacina: v %>\n",
      "app/views/caderneta/_doses.html.erb" => "<%= Current.caderneta %>\n"
    ) do |g|
      expect(g.dynamic?).to be(false)
      expect(g.renderers_of("caderneta/doses")).to eq(["caderneta/index.html.erb"])
      expect(g.file_for("caderneta/doses")).to eq("caderneta/_doses.html.erb")
      expect(g.external).to be_empty
    end
  end

  it "records `render partial: 'shared/menu'` with an explicit path" do
    graph(
      "app/views/posts/show.html.erb" => "<%= render partial: 'shared/menu' %>\n",
      "app/views/shared/_menu.html.erb" => "x\n"
    ) do |g|
      expect(g.dynamic?).to be(false)
      expect(g.renderers_of("shared/menu")).to eq(["posts/show.html.erb"])
    end
  end

  it "captures partial→partial edges" do
    graph(
      "app/views/posts/show.html.erb" => "<%= render 'outer' %>\n",
      "app/views/posts/_outer.html.erb" => "<%= render 'inner' %>\n",
      "app/views/posts/_inner.html.erb" => "x\n"
    ) do |g|
      expect(g.renderers_of("posts/outer")).to eq(["posts/show.html.erb"])
      expect(g.renderers_of("posts/inner")).to eq(["posts/_outer.html.erb"])
    end
  end

  describe "dynamic renders (conservative completeness bail)" do
    it "flags `render partial: variable`" do
      graph("app/views/posts/show.html.erb" => "<%= render partial: name %>\n") do |g|
        expect(g.dynamic?).to be(true)
      end
    end

    it "flags `render @collection`" do
      graph("app/views/posts/index.html.erb" => "<%= render @posts %>\n") do |g|
        expect(g.dynamic?).to be(true)
      end
    end

    it "flags a view it cannot parse to Ruby" do
      graph("app/views/posts/show.html.erb" => "<%= render 'ok' %>\n<% def %>\n") do |g|
        expect(g.dynamic?).to be(true)
      end
    end
  end

  describe "non-partial renders are ignored" do
    it "ignores `render :action` (template render)" do
      graph("app/views/posts/show.html.erb" => "<%= render :sidebar %>\n") do |g|
        expect(g.dynamic?).to be(false)
        expect(g.edges).to be_empty
      end
    end

    it "ignores a ViewComponent render (`render Comp.new` / `render Comp`)" do
      graph(
        "app/views/posts/show.html.erb" => "<%= render PostCard.new(post) %>\n",
        "app/views/posts/index.html.erb" => "<%= render PostCard %>\n"
      ) do |g|
        expect(g.dynamic?).to be(false)
        expect(g.edges).to be_empty
      end
    end

    it "ignores a receivered `obj.render(...)` (unrelated method)" do
      graph("app/views/posts/show.html.erb" => "<% pdf.render 'doses' %>\n") do |g|
        expect(g.dynamic?).to be(false)
        expect(g.edges).to be_empty
      end
    end

    it "ignores `render json:`/`render plain:` (no partial)" do
      graph("app/controllers/api_controller.rb" => <<~RUBY) do |g|
        class ApiController < ApplicationController
          def show
            render json: { ok: true }
          end
        end
      RUBY
        expect(g.dynamic?).to be(false)
        expect(g.external).to be_empty
      end
    end
  end

  describe "external renders (no single guarded action covers them)" do
    it "marks a partial rendered from a layout external" do
      graph(
        "app/views/layouts/application.html.erb" => "<%= render 'shared/flash' %>\n",
        "app/views/shared/_flash.html.erb" => "x\n"
      ) do |g|
        expect(g.external).to include("shared/flash")
        expect(g.renderers_of("shared/flash")).to be_empty
      end
    end

    it "marks a partial rendered from a controller external" do
      graph("app/controllers/posts_controller.rb" => <<~RUBY) do |g|
        class PostsController < ApplicationController
          def show
            render partial: "posts/row"
          end
        end
      RUBY
        expect(g.external).to include("posts/row")
      end
    end

    it "marks a partial rendered from a helper external" do
      graph("app/helpers/posts_helper.rb" => <<~RUBY) do |g|
        module PostsHelper
          def widget
            render "shared/widget"
          end
        end
      RUBY
        expect(g.external).to include("shared/widget")
      end
    end
  end

  describe "unparseable HTML template languages" do
    it "bails when a .haml view exists (could render an html partial unseen)" do
      graph(
        "app/views/posts/show.html.erb" => "<%= render 'row' %>\n",
        "app/views/posts/index.html.haml" => "= render 'row'\n"
      ) do |g|
        expect(g.dynamic?).to be(true)
      end
    end
  end
end
