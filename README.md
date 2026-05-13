# RbsInfer

Infer RBS type signatures from Ruby source code via static analysis using [Prism](https://github.com/ruby/prism), backed by [Steep](https://github.com/soutaro/steep) and [RBS](https://github.com/ruby/rbs) for downstream type checking.

No annotations required — types are inferred from `initialize` call-sites, `attr` assignments, method bodies, return statements, collection operations, and (in Rails projects) controller actions, partial render call-sites, and `enumerize` declarations.

## Status

Pre-release (`0.1.0`); not yet published to RubyGems. Add via local path or git:

```ruby
# Gemfile
gem "rbs_infer", path: "../rbs_infer"
# or
gem "rbs_infer", git: "https://github.com/felixefelip/rbs_infer.git"
```

Requires Ruby >= 3.3.0 and the runtime deps in [`rbs_infer.gemspec`](rbs_infer.gemspec): `prism (>= 1.0)`, `rbs`, `steep`.

## CLI

```bash
# Print RBS to stdout for a single file
bundle exec rbs_infer app/models/user.rb

# Print RBS for every .rb file under a directory
bundle exec rbs_infer app/models

# Write each RBS next to its source (default: sig/generated/<original-path>.rbs)
bundle exec rbs_infer app/models --output

# Custom output dir (implies --output)
bundle exec rbs_infer app/models --output-dir sig/rbs_infer

# Tune iterative convergence (default 10 passes)
bundle exec rbs_infer app/ --output --max-passes 15
```

When `--output` is enabled the analyzer runs in dependency order (topological sort over `RbsInfer::DependencySorter`) and then re-runs files whose RBS still changes — that's the *stabilization pass loop* controlled by `--max-passes`.

## Ruby API

```ruby
require "rbs_infer"

rbs = RbsInfer::Analyzer.new(
  target_class: "User",
  target_file:  "app/models/user.rb",
  source_files: Dir["app/**/*.rb"]
).generate_rbs

puts rbs
```

The `Analyzer` orchestrates `ClassMemberCollector`, `InitializeBodyAnalyzer`, `IntraClassCallAnalyzer`, `NewCallCollector`, `ParamTypeInferrer`, `ReturnTypeResolver`, `ClassBodyAttrAnalyzer`, `RbsBuilder`, and merges everything via `TypeMerger`. See `lib/rbs_infer/` for the components.

## What it infers

- `initialize` parameter types from call-sites (`User.new(name: "Jo")` → `String`)
- Optional parameters with defaults
- `attr_reader` / `attr_writer` / `attr_accessor` types from assignments and usage
- Method return types (literals, constants, method calls, forwarding, collection ops)
- Element types for arrays/hashes from operations (`array << Item.new` → `Array[Item]`)
- Module vs class detection and nested class naming
- Cross-call resolution via `RbsTypeLookup` / `MethodTypeResolver` (resolves types using existing RBS, including stdlib, gems via `gem_rbs_collection`, and previously-generated `sig/`)

## Rails extensions

Loaded automatically when running inside a Rails app via [`RbsInfer::Railtie`](lib/rbs_infer/railtie.rb). All three rake tasks are registered without an explicit `require`:

| Task | Source generator | Output dir |
|---|---|---|
| `rake rbs_infer:enumerize:all` | `RbsInfer::Extensions::Enumerize::Generator` | `sig/rbs_enumerize/` |
| `rake rbs_infer:rails_custom:all` | `RbsInfer::Extensions::Rails::CustomGenerator` | `sig/rbs_rails_custom/` |
| `rake rbs_infer:erb:all` | `RbsInfer::Extensions::Rails::ErbConventionGenerator` | `sig/rbs_infer_erb/` |

**Enumerize generator** — walks `app/models/**/*.rb`, captures `enumerize :attr, in: [...]`, and emits per-attribute `Value` / `Attribute` classes plus instance/class accessors, predicate methods, and scope methods (shallow/deep).

**Rails custom generator** — emits `application_controller.rbs` and `action_view_context.rbs` with framework-level mix-ins (`ApplicationHelper`, `ActionView::Helpers`, optionally `Kaminari::Helpers`, `_RbsRailsPathHelpers`) so controllers/views resolve helper methods.

**ERB convention generator** — uses Steep's ERB module convention (`STEEP_ERB_CONVENTION=1`). For each `app/views/**/*.{html,turbo_stream}.erb`, it emits a corresponding `class ERB<Controller><Action>` (or `ERBPartial<Controller><Name>` for `_partial.html.erb`) with:
- instance variables typed from the matching controller action,
- partial locals typed by collecting every `render partial: "...", locals: { ... }` call-site,
- `params: () -> ActionController::Parameters`,
- helper modules included.

## Layout

```
bin/rbs_infer                                # CLI
lib/rbs_infer/
  analyzer.rb                                # orchestrator
  class_member_collector.rb, def_collector.rb, ...
  rbs_builder.rb, type_merger.rb             # RBS assembly
  rbs_type_lookup.rb, method_type_resolver.rb,
  rbs_definition_resolver.rb, steep_bridge.rb # cross-call resolution via RBS/Steep
  parse_cache.rb, file_index.rb,
  source_index.rb, caller_file_cache.rb      # caches that drive perf
  railtie.rb                                 # auto-registers rake tasks
  extensions/
    enumerize/                               # Enumerize generator
    rails/
      custom_generator.rb                    # ApplicationController / ActionViewContext
      erb_convention_generator.rb            # ERB module convention
      erb_caller_resolver.rb                 # helpers ↔ ERB call-sites
spec/
  dummy/                                     # Rails 8 dummy app used by integration suite
  integration/rails_dummy_spec.rb            # snapshot tests vs spec/expectations/
  expectations/                              # checked-in expected RBS output
  lib/rbs_infer/                             # unit specs
docs/tasks/                                  # design notes / open work
```

## Development workflow

The `spec/dummy/` Rails 8 app is the integration playground. Most work consists of:
1. Add/modify fixtures under `spec/dummy/app/`.
2. Regenerate the relevant snapshots.
3. Run `bundle exec rspec spec/integration/`.
4. Optionally run `steep check` inside the dummy to validate generated RBS against real source.

### Makefile shortcuts (run at the repo root)

```bash
make rbs_infer            # run rbs_infer on spec/dummy/app/models/
make rbs_models           # alias of above
make rbs_controllers      # spec/dummy/app/controllers/
make rbs_services         # spec/dummy/app/services/
make rbs_helpers          # spec/dummy/app/helpers/

make rbs_rails_generator  # cd spec/dummy && rake rbs_rails:all
make rbs_rails_custom     # ApplicationController + ActionViewContext
make rbs_infer_enumerize  # rake rbs_infer:enumerize:all
make rbs_infer_erb        # ERB convention RBS
make rbs_generators_all   # all four above, in order

make test                 # bundle exec rspec
make steep                # STEEP_ERB_CONVENTION=1 STEEP_MODULE_CONVENTION=1 steep check
```

### Snapshot tests

`spec/integration/rails_dummy_spec.rb` calls `RbsInfer::Analyzer` (and the extension generators) against the dummy app and compares the output against checked-in expectations under `spec/expectations/`. To regenerate after an intentional change:

```bash
UPDATE_EXPECTATIONS=1 bundle exec rspec spec/integration/
```

Review the resulting diff against the previous expectation before committing.

### Unit specs

```bash
bundle exec rspec spec/lib/                  # all unit specs
bundle exec rspec spec/lib/rbs_infer/analyzer_spec.rb
```

## Steep integration

`RbsInfer::SteepBridge` keeps a long-lived Steep environment loaded so the analyzer can resolve method return types against existing RBS (stdlib, gems, Rails, your own previously-generated `sig/`). When `--output` regenerates files, `SteepBridge.reset!` is called between dependency levels so each pass sees the previously-emitted RBS. This is what lets call-chains across files converge in `--max-passes` iterations.

## Performance

The hot paths are file parsing and RBS lookups. Caches that materially affect throughput:

- `RbsInfer::ParseCache` — memoizes `Prism.parse` per file.
- `RbsInfer::FileIndex` — O(1) file lookup by class path.
- `RbsInfer::SourceIndex` — class → defining file pre-built from a single sweep.
- Per-file RBS declaration index — avoids re-running `RBS::Parser.parse_signature` for repeated class lookups in the same file.

See `docs/tasks/performance_optimizations.md` for measured results and rejected approaches.

## Design notes / open work

`docs/tasks/` holds plans and gap analyses:

- [`type_inference_gaps.md`](docs/tasks/type_inference_gaps.md) — patterns the analyzer still misses (constant receivers, `||`/`||=`, ternaries, comparison results, etc.), with a coverage matrix and prioritized implementation order. Appendix covers per-gem coverage (e.g. CarrierWave).
- [`enumerize_generator_gaps.md`](docs/tasks/enumerize_generator_gaps.md) + [`enumerize_class_accessors_and_modules.md`](docs/tasks/enumerize_class_accessors_and_modules.md) — pending enumerize work.
- [`erb_type_convention.md`](docs/tasks/erb_type_convention.md), [`helper_type_convention.md`](docs/tasks/helper_type_convention.md) — Rails view/helper conventions.
- [`carrierwave_mount_uploader_generator.md`](docs/tasks/carrierwave_mount_uploader_generator.md) — proposed generator for `mount_uploader`.
- [`steep_integration_plan.md`](docs/tasks/steep_integration_plan.md), [`steep_inspired_improvements.md`](docs/tasks/steep_inspired_improvements.md), [`rbs_based_type_resolution.md`](docs/tasks/rbs_based_type_resolution.md) — how the Steep dependency works and what we still want from it.
- [`performance_optimizations.md`](docs/tasks/performance_optimizations.md) — perf playbook.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
