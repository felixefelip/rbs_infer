---
name: review-pr
description: Review a pull request in one of the three fork repos (rbs_infer, steep, rbs_rails) for hacks and for re-implementing infrastructure that already exists (postconditions, sidecars, contracts, expanders, shared walkers, reachability). Use when asked to review/revise a PR by URL or number.
---

# Review a PR for hacks and missed reuse

The argument is a PR URL or `<repo>#<number>`. The repos are `felixefelip/rbs_infer`,
`felixefelip/steep` (checkout at `../steep`) and `felixefelip/rbs_rails` (`../rbs_rails`).

## 1. Look for what already exists

For every new module, walker, constant, table or special case, search the target repo for
the infrastructure it might duplicate before judging it:

- **AST walkers** (`return`/tail/scope traversal): `LocalReach`, `Accumulators`
  (`each_tail`, `each_returns`, `SCOPES`, `JUMPS`), `Postconditions::Inferrer`.
- **Reachability / dead branches**: `Specializations::Evals::Flow`, `Evals::UNREACHABLE`,
  `typing.arm_of`, the `UnreachableBranch`/`UnreachableValueBranch` diagnostics.
- **Facts about values or methods**: postconditions (`.steep_postconditions`), contracts
  (`Steep::Contracts`), callbacks, specializations / string-eval sidecars, literal intrinsics.
- **rbs_infer seams**: `Project::SourceExpanders`, `Project::SelfTypeAnnotators`, generators.
  Framework knowledge in `lib/rbs_infer/{ast,inference,signatures}` is a finding
  (`docs/engineering/keep-core-framework-agnostic.md`).
- **Existing decision tables** in `type_construction.rb` (`:and`/`:or`/`:if`/`:case`): a
  new module that overrides their result after the fact is a second table, not a fix.

Hacks to flag:
- syntactic matching where the semantic machinery already answers;
- a patch layered after the defective code instead of fixing it there;
- a new constant equal to an existing one;
- a fix scoped to one shape (e.g. only `if condition`) when the defect is general;
- a defaulted kwarg that should be required (`docs/engineering/required-threaded-deps.md`);
- comments that justify the change instead of explaining hard code
  (`docs/engineering/comments-only-when-code-is-hard.md`).

## 2. Confirm with a probe

A suspected gap is only a finding once it has been reproduced: write a throwaway test next
to the PR's test and run only that file. Don't run the steep full suite or `steep check` on
Fizzy.

## 3. Report

First answer in the chat, in Portuguese. For each finding, give the file:line, the existing
resource it should reuse, and the probe result if there is one. End with a recommendation.

When asked to post it, post one review in English, with inline comments on the diff lines
and a summary body, as a plain comment: GitHub rejects requesting changes on your own PR.
