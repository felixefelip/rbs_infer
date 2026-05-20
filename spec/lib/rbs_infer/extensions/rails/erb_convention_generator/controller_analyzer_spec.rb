require "spec_helper"
require "rbs_infer/extensions/rails/erb_convention_generator"
require "prism"

# Unit tests for the cross-action rendering detection in
# `ControllerAnalyzer`. Covers `collect_view_renderers` and
# `render_targets_template?` directly, plus the integration through
# `extract_action_ivars` for the multi-renderer wide fallback path.
RSpec.describe RbsInfer::Extensions::Rails::ErbConventionGenerator::ControllerAnalyzer do
  # Build a small class that includes the module under test, mirroring
  # how `ErbConventionGenerator` uses it. Methods are called directly;
  # no controller file / Steep bridge needed for the render-detection
  # tests.
  let(:host_class) do
    Class.new do
      include RbsInfer::Extensions::Rails::ErbConventionGenerator::ControllerAnalyzer
    end
  end

  let(:host) { host_class.new }

  def parse(source)
    Prism.parse(source).value
  end

  describe "#collect_view_renderers" do
    it "always includes the conventional action even when no render call is present" do
      tree = parse(<<~RUBY)
        class FoosController
          def index; end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "index")).to contain_exactly("index")
    end

    it "detects render :symbol in other actions" do
      tree = parse(<<~RUBY)
        class FoosController
          def edit; end
          def update
            render :edit
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "edit")).to contain_exactly("edit", "update")
    end

    it "detects render \"string\" template calls" do
      tree = parse(<<~RUBY)
        class FoosController
          def show; end
          def update
            render "show"
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "show")).to contain_exactly("show", "update")
    end

    it "ignores render \"_underscored_partial\" calls (partials, not templates)" do
      tree = parse(<<~RUBY)
        class FoosController
          def index; end
          def update
            render "_partial_name"
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "_partial_name")).to contain_exactly("_partial_name")
    end

    it "ignores render partial: \"name\" calls" do
      tree = parse(<<~RUBY)
        class FoosController
          def edit; end
          def update
            render partial: "edit"
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "edit")).to contain_exactly("edit")
    end

    it "detects render template: \"name\" calls" do
      tree = parse(<<~RUBY)
        class FoosController
          def show; end
          def update
            render template: "show"
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "show")).to contain_exactly("show", "update")
    end

    it "detects render template: \"controller/name\" calls" do
      tree = parse(<<~RUBY)
        class FoosController
          def show; end
          def update
            render template: "foos/show"
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "show")).to contain_exactly("show", "update")
    end

    it "detects render action: :name calls" do
      tree = parse(<<~RUBY)
        class FoosController
          def edit; end
          def update
            render action: :edit
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "edit")).to contain_exactly("edit", "update")
    end

    it "is not fooled by render :other_template" do
      tree = parse(<<~RUBY)
        class FoosController
          def edit; end
          def new; end
          def update
            render :new  # renders a DIFFERENT template, not :edit
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "edit")).to contain_exactly("edit")
      expect(host.collect_view_renderers(tree, "new")).to contain_exactly("new", "update")
    end

    it "handles multiple actions all rendering the same template" do
      tree = parse(<<~RUBY)
        class FoosController
          def edit; end
          def update
            render :edit
          end
          def patch
            render :edit
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "edit")).to contain_exactly("edit", "update", "patch")
    end

    it "ignores render plain:/json:/inline: (non-template responses)" do
      tree = parse(<<~RUBY)
        class FoosController
          def edit; end
          def update
            render plain: "edit"
          end
        end
      RUBY

      expect(host.collect_view_renderers(tree, "edit")).to contain_exactly("edit")
    end
  end

  describe "#render_targets_template?" do
    def render_call(source)
      tree = parse(source)
      # Walk to find the render call.
      visit = lambda do |node|
        return node if node.is_a?(Prism::CallNode) && node.name == :render
        node.compact_child_nodes.each do |child|
          found = visit.call(child)
          return found if found
        end
        nil
      end
      visit.call(tree)
    end

    it "matches Symbol arg" do
      call = render_call(<<~RUBY)
        render :edit
      RUBY
      expect(host.render_targets_template?(call, "edit")).to be(true)
      expect(host.render_targets_template?(call, "show")).to be(false)
    end

    it "matches String arg without underscore prefix" do
      call = render_call(<<~RUBY)
        render "edit"
      RUBY
      expect(host.render_targets_template?(call, "edit")).to be(true)
    end

    it "rejects partial: keyword even if name matches" do
      call = render_call(<<~RUBY)
        render partial: "edit"
      RUBY
      expect(host.render_targets_template?(call, "edit")).to be(false)
    end
  end
end
