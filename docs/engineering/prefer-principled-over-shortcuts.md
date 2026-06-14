## Prefer principled implementations over expedient shortcuts

When a feature can be built either by leveraging existing infrastructure/semantics or by
a syntactic / pattern-matching shortcut that merely "works for V1", choose the principled
path — even when it costs more code up front.

Syntactic shortcuts are brittle: they miss equivalent shapes, duplicate work the real
machinery already does semantically, and drift as that machinery evolves. Going through
existing infra pays back in coverage, composability, and correctness.

Reserve shortcuts for: (1) genuinely trivial cases with no existing infra to leverage;
(2) explicit throwaway/prototype code; (3) cases where the principled path would force
invasive changes to internal APIs you don't trust.

Don't surface "quick V1 vs proper engineering" as a choice for the user — the answer is
already "proper". Raise a trade-off only when there's genuine ambiguity *beyond*
engineering quality.
