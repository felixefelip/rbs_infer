# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

# The expanded view is the pipeline's real INPUT for every file a macro touches:
# `SourceExpanders` desugar the macros, and everything downstream reads the
# result rather than the file on disk. `bin/rbs_infer` dumps it under
# `sig/.../.expanded/` to be read, but nothing asserted it — so an expander could
# change what it produces and, as long as the emitted RBS happened not to move,
# say nothing. That is not hypothetical: the replay expander's indentation took
# two commits of back-and-forth (felixefelip/rbs_infer#239) with no snapshot to
# hold it, and `.expanded/app/models/zz_args.rb` outlived the fixture it was
# generated from by months.
#
# Two assertions, because they fail on opposite mistakes:
#
#   * the SET — an expander that starts firing on a file it should not touch
#     rewrites that file's whole input, and no per-file snapshot would notice
#     because no expectation exists for it yet;
#   * the CONTENT — an expander that keeps firing but produces something else.
#
# No `before(:all)` generator sweep here, unlike `rails_dummy_spec`: expansion
# reads sources and nothing else — no database, no rbs_rails, no Steep.
RSpec.describe "expanded sources", :dummy_app do
  # `.expanded/` is invisible to this glob (a leading dot is exactly why the
  # directory is named that way), so the dumped views are never read back in as
  # sources of their own.
  # The same three roots the Makefile hands the CLI. `lib/` matters and is easy
  # to leave out: a DSL's applier can be a reopening of a core class, which by
  # convention lives under `lib/` and is where nothing else would look for it
  # (felixefelip/rbs_infer#256). Omitting it made this spec assert an expanded
  # view the pipeline never actually produces.
  let(:source_files) { Dir["app/**/*.rb"] + Dir["lib/**/*.rb"] + Dir["sig/**/*.rb"] }
  let(:expectations_dir) { Pathname.new(File.expand_path("../expectations/expanded", __dir__)) }

  # path => expanded source, for every dummy source an expander rewrites.
  # `load_and_parse_target` is the step that produces it, and it is the whole
  # step: running `generate_rbs` would make this snapshot depend on inference
  # too, which the RBS expectations already cover.
  def expansions
    Dir["app/**/*.rb"].sort.each_with_object({}) do |path, found|
      analyzer = RbsInfer::Analyzer.new(target_file: path, source_files: source_files)
      analyzer.load_and_parse_target
      found[path] = analyzer.expanded_source if analyzer.expanded_source
    end
  end

  # To regenerate after an intentional change:
  #   UPDATE_EXPECTATIONS=1 bundle exec rspec spec/integration/
  before do
    next unless ENV["UPDATE_EXPECTATIONS"]

    expectations_dir.rmtree if expectations_dir.exist?
    expansions.each do |path, expanded|
      out = expectations_dir.join(path)
      out.dirname.mkpath
      out.write(expanded)
    end
  end

  it "expands exactly the sources whose macros the pipeline desugars" do
    expected = expectations_dir.glob("**/*.rb").map { |p| p.relative_path_from(expectations_dir).to_s }.sort

    expect(expansions.keys).to eq(expected)
  end

  it "expands each of them into the checked-in pseudo-code" do
    expansions.each do |path, expanded|
      expect(expanded).to eq(expectations_dir.join(path).read), "expanded view of #{path} changed"
    end
  end
end
