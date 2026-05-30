# AGENTS.md

Instructions for AI agents working in this repository. See `README.md` for what
RbsInfer does and the project's zero-annotation goal.

## Conventions

Read these before making changes — they encode lessons learned in this codebase:

- [`docs/conventions/method-signatures.md`](docs/conventions/method-signatures.md) —
  Check every call site before adding or changing a method signature. Unnecessary
  default values and optional keywords hide bugs; the callers define the contract.

## Working in this repo

- Run the test suite with `bundle exec rspec`. Keep it green before committing.
- Match the style of the surrounding code; comments in this repo are often in
  Portuguese — follow the local convention of the file you're editing.
- Commit and push only when explicitly asked.
