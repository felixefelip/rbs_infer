require "spec_helper"
require "rbs_infer/extensions/rails/erb_caller_resolver"

RSpec.describe RbsInfer::Extensions::Rails::ErbCallerResolver do
  subject(:resolver) { described_class.new(app_dir: "/tmp/none", source_files: []) }

  describe "#reset_cache!" do
    # Direct unit test on the cache lifecycle. The bug we fixed lived in
    # the interaction between this cache and the `bin/rbs_infer`
    # stabilization loop: between passes, `SteepBridge.reset!` was called
    # but `@erb_ivar_cache` survived, so the resolver returned the empty
    # controller-ivar result it had computed under a broken Steep env.
    # This spec pins the contract `reset_cache!` exposes for the CLI.
    it "drops cached controller-ivar entries" do
      cached = { "orders" => "Order::ActiveRecord_Relation" }
      resolver.instance_variable_set(
        :@erb_ivar_cache,
        { "OrdersController#index" => cached }
      )

      expect(resolver.instance_variable_get(:@erb_ivar_cache))
        .to include("OrdersController#index" => cached)

      resolver.reset_cache!

      cleared = resolver.instance_variable_get(:@erb_ivar_cache)
      expect(cleared).to satisfy { |c| c.nil? || c.empty? }
    end

    it "is a no-op when no cache has been populated" do
      expect(resolver.instance_variable_get(:@erb_ivar_cache)).to be_nil
      expect { resolver.reset_cache! }.not_to raise_error
    end

    it "lets the next lookup miss instead of returning a stale value" do
      # The whole point: after `reset_cache!`, the `return … if … key?(key)`
      # short-circuit in `erb_ivar_types` no longer fires for the prior
      # key, so the resolver gets a chance to recompute against the fresh
      # Steep env.
      key = "OrdersController#index"
      resolver.instance_variable_set(:@erb_ivar_cache, { key => { "orders" => "Stale" } })

      resolver.reset_cache!

      cache = resolver.instance_variable_get(:@erb_ivar_cache)
      expect(cache.nil? || !cache.key?(key)).to be true
    end
  end

  describe "#erb_ivar_types (private)" do
    # Regression for the ivar-vs-local name collision in helper
    # inference: the keys in the returned hash must be prefixed with
    # `@` so downstream consumers (CallerFileAnalyzer, NewCallCollector)
    # can distinguish an ivar lookup from a local-var lookup with the
    # same basename. Before the fix, `{ "company" => "..." }` would
    # shadow a `company` block-param of unrelated type.

    let(:tmpdir) { Dir.mktmpdir }
    let(:resolver_with_dir) do
      described_class.new(app_dir: tmpdir, source_files: [])
    end

    after { FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir) }

    def with_controller_file(controller_path, &)
      full = File.join(tmpdir, controller_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "class PostsController; end")
      yield full
    end

    it "keys ivar entries with the leading @" do
      with_controller_file("app/controllers/posts_controller.rb") do |_|
        fake_rbs = <<~RBS
          class PostsController < ApplicationController
            @company: ((Company & Company::Validated) | Company)?
            @posts: Post::ActiveRecord_Relation?
            def index: () -> void
          end
        RBS
        fake_analyzer = instance_double(RbsInfer::Analyzer, generate_rbs: fake_rbs)
        allow(RbsInfer::Analyzer).to receive(:new).and_return(fake_analyzer)

        result = resolver_with_dir.send(:erb_ivar_types, "posts/index.html.erb", [])

        expect(result.keys).to contain_exactly("@company", "@posts")
        # Outer `?` is stripped: views render after the action, so an
        # ivar declared nilable at the controller level is in practice
        # always set by view time. Keeping `?` would leak nil into
        # helper param types.
        expect(result["@company"]).to eq("(Company & Company::Validated) | Company")
        expect(result["@posts"]).to eq("Post::ActiveRecord_Relation")
      end
    end

    it "returns empty hash for partial templates (filename starts with _)" do
      # Partials don't map to a controller action by convention, so the
      # ivar lookup is skipped — partial locals come from the
      # `render :partial, locals: {...}` call site.
      result = resolver_with_dir.send(:erb_ivar_types, "posts/_form.html.erb", [])
      expect(result).to eq({})
    end

    it "returns empty hash when the matching controller file does not exist" do
      result = resolver_with_dir.send(:erb_ivar_types, "missing/index.html.erb", [])
      expect(result).to eq({})
    end

    it "caches by controller#action pair" do
      with_controller_file("app/controllers/posts_controller.rb") do |_|
        fake_rbs = "class PostsController\n  @x: String\nend\n"
        fake_analyzer = instance_double(RbsInfer::Analyzer, generate_rbs: fake_rbs)
        expect(RbsInfer::Analyzer).to receive(:new).once.and_return(fake_analyzer)

        first = resolver_with_dir.send(:erb_ivar_types, "posts/index.html.erb", [])
        second = resolver_with_dir.send(:erb_ivar_types, "posts/index.html.erb", [])

        expect(first).to eq(second)
        expect(first).to eq({ "@x" => "String" })
      end
    end
  end
end
