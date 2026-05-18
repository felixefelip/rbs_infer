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
end
