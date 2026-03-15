# RbsInfer

Infer RBS type signatures from Ruby source code via static analysis using [Prism](https://github.com/ruby/prism).

No annotations required — types are inferred from `initialize` call-sites, `attr` assignments, method bodies, collection operations, and more.

## Installation

Add to your `Gemfile`:

```ruby
gem "rbs_infer"
```

Or install directly:

```
gem install rbs_infer
```

## Usage

### CLI

```bash
# Generate RBS for all .rb files under a directory
rbs_infer app/models

# Output to stdout
rbs_infer app/models/user.rb --output stdout

# Output each .rbs next to its .rb source
rbs_infer app/models --output-dir sig/generated
```

### Ruby API

```ruby
require "rbs_infer"

analyzer = RbsInfer::Analyzer.new
analyzer.process_file("app/models/user.rb")
puts analyzer.generate_rbs
```

## What It Infers

- `initialize` parameter types from call-sites (`User.new(name: "Jo")` → `String`)
- `attr_reader` / `attr_writer` / `attr_accessor` types
- Method return types (literals, constants, calls, forwarding, collection ops)
- Optional parameters (with defaults)
- Collection element types (`array << Item.new` → `Array[Item]`)
- Hash key/value types
- Module vs class detection
- Nested class naming
- Mailer-style method generation

## Requirements

- Ruby >= 3.3.0
- Prism >= 1.0

## License

MIT
