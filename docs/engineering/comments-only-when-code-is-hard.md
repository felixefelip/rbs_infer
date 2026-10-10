## Comment only when the code is hard to read

A comment is a failure to express something in code (Clean Code, ch. 4). Before writing
one, try to turn it into a variable name, a method name, or a smaller method. Comment
only what survives that attempt — typically a warning of consequence ("simplifying this
to X breaks Y"), or an implementation that is genuinely hard to follow.

What does **not** go above the lines:

- **Why the change was made**, what the code did before, or why the approach is sound.
  That belongs in the commit message and the PR description, where it is tied to the
  change instead of aging next to code that keeps moving.
- **Narration** of what the next line does, when its names already say it.
- **Spec prose** restating the example's name. If the `it` string says the intent, a
  comment above it is redundant.

Annotations are not comments in this sense: `# @type`, `#:`, `# @rbs_infer ...` and
`# rubocop:disable` are read by tools and stay.

### Don't match the surrounding comment density

"Write like the surrounding code" does not extend to comments. A neighbouring file being
heavily commented is not license to comment as much — that density may itself be debt, or
may be mostly annotations rather than prose. Apply the rule above to every comment you add,
whatever the file around it looks like.

Real miss (felixefelip/steep#163, #164): a 4-line change shipped with 13 lines of prose
explaining why it was correct, imported from the style of
`lib/steep/postconditions/runner.rb` (~35% comment lines) into
`lib/steep/type_construction.rb` (~12%, much of it `# @type`). The explanation belonged in
the PR body; the code needed none of it.
