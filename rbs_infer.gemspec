# frozen_string_literal: true

require_relative "lib/rbs_infer/version"

Gem::Specification.new do |spec|
  spec.name = "rbs_infer"
  spec.version = RbsInfer::VERSION
  spec.authors = ["Felipe Felix"]
  spec.summary = "Infer RBS type signatures from Ruby source code via static analysis"
  spec.description = <<~DESC
    RbsInfer generates RBS type signatures automatically from Ruby source code
    using static analysis via Prism parser. No annotations required — types are
    inferred from initialize call-sites, attr assignments, method bodies,
    collection operations, and more.
  DESC
  spec.homepage = "https://github.com/felixefelip/rbs_infer"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.rake", "bin/*", "README.md", "LICENSE.txt"]
  spec.bindir = "bin"
  spec.executables = ["rbs_infer"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0"
  spec.add_dependency "rbs"

  spec.add_development_dependency "rspec", "~> 3.0"
end
