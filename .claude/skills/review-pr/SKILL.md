---
name: review-pr
description: Review a pull request in one of the three fork repos (rbs_infer, steep, rbs_rails) for hacks and for re-implementing infrastructure that already exists (postconditions, sidecars, contracts, expanders, shared walkers, reachability). Use when asked to review/revise a PR by URL or number.
---

# Review a PR for hacks and missed reuse

The argument is a PR URL or `<repo>#<number>`. The repos are `felixefelip/rbs_infer`,
`felixefelip/steep` (checkout at `../steep`), `felixefelip/rbs_rails` (`../rbs_rails`).
Always pass `--repo felixefelip/<repo>` to `gh`.

## 1. Read the change

```bash
gh pr view <n> --repo felixefelip/<repo> --json title,body,headRefName,baseRefName,files,commits
gh pr diff <n> --repo felixefelip/<repo>
```

## 2. Look for what already exists

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

## 3. Confirm with a probe

A suspected gap is only a finding once it has been reproduced. Check out the PR head in a
worktree in the scratchpad (never switch `../steep`'s own checkout; the dummy bundle follows
it), write a throwaway test next to the PR's test, run only that file, then remove the
worktree:

```bash
git -C ../steep fetch -q origin <head-branch>
git -C ../steep worktree add -q <scratchpad>/pr<n> FETCH_HEAD
# ... bundle exec ruby -Ilib -Itest test/<probe>_test.rb -n test_probe
git -C ../steep worktree remove --force <scratchpad>/pr<n>
```

Don't run the steep full suite or `steep check` on Fizzy.

## 4. Report

First answer in the chat, in Portuguese. For each finding, give the file:line, the existing
resource it should reuse, and the probe result if there is one. End with a recommendation.

When asked to post it, send one review via the API, in English, with inline comments on the
diff lines and a summary body. Use `"event": "COMMENT"`, because GitHub rejects
`REQUEST_CHANGES` on your own PR:

```bash
gh api -X POST repos/felixefelip/<repo>/pulls/<n>/reviews --input review.json --jq .html_url
# review.json: { "commit_id", "event": "COMMENT", "body", "comments": [{ "path", "line", "side": "RIGHT", "body" }] }
```

`commit_id` must be the full 40-char SHA of the PR head (`git rev-parse`), or the API answers 422.
Inline `line`s must be lines of the diff at that commit (`git show <sha>:<path> | grep -n`).
