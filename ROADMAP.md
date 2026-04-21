# Roadmap

The big picture for closing graded's remaining analysis gaps. Ordered by
sequencing, not by size.

Current state: **0.5.0** shipped first-order effect polymorphism —
effect variables at function boundaries, call-site substitution for
higher-order functions, dependency parameter positions via glance.

The gaps that remain are documented in [README.md](./README.md#limitations):

- Field calls on locally-constructed records don't substitute.
- Nested (second-order) polymorphism — callbacks that take callbacks —
  isn't tracked.
- Expression-level type info isn't available, which forces label/position
  heuristics for argument matching.

The milestones below address these progressively.

---

## 0.6.0 — Same-function value flow ✅

**Shipped.** Closed the biggest real-world gap (field calls on
locally-constructed records) with a targeted extractor addition. No
change to the effect representation.

**Delivered:**

- Local binding environment threaded through function-body walks.
- Four binding classifications: `BoundFunctionRef`, `BoundAlias`,
  `BoundConstructor`, `BoundOpaque`.
- Env-aware resolution at `Variable` callees, pipe targets, and
  argument classification.
- Same-module constructor label registry so positional arguments
  (`Validator(io.println)`) resolve the same as labelled
  (`Validator(to_error: io.println)`).
- Shadowing handled by env overwrite; block and fn-closure bodies
  walk a child scope whose bindings don't leak out.
- Pattern destructuring, `use`-bound names, record updates → tracked
  as `BoundOpaque` (explicit follow-ups).

**Does not cross function boundaries** — construction in a caller
remains opaque. Cross-module constructor labels are also not yet
indexed; unlabelled cross-module constructor args fall into
`positional`.

---

## 0.7.0 — Function-argument effect unification (#3a)

**Goal:** propagate effect variables through nested higher-order calls.
A function taking a callback that itself takes a callback resolves
transitively instead of bottoming out at `[Unknown]`.

**Scope:**

- New effect term representation:
  `EffectTerm = Concrete(Set(String)) | Variable(String) | Union(...)`
- Two-phase analysis: collect subset constraints, solve by fixpoint
  iteration, then check against declared bounds.
- Substitute solved variables back into inferred specs; unsolved
  variables surface as polymorphic signatures (syntax already exists).
- Error messages redesigned: a violation means "no assignment to free
  vars makes `A ⊇ B` hold." Needs explicit UX work.

**Architectural cost:** medium refactor — every place that returns
`Set(String)` in the analysis pipeline gains the richer term type. The
solver algorithm itself is ~150 lines; the refactor is the real cost.

**Estimate:** 3–4 weeks focused.

**Risk:** error-message usability. Technically-correct violations that
users can't act on. Budget design time for this.

---

## Later — Record types with effect vars (#3b)

**Goal:** full propagation of effect variables through record
construction and field access. Subsumes 0.6.0's value-flow hack and
retires the need for per-type field annotations in most cases.

**Blocked on:** expression-level type information. Two possible
unblocks, neither actionable inside graded alone:

- **Upstream:** the Gleam compiler exposing typed AST to third-party
  tools. Zero cost to us today; long lead time. Worth opening a
  discussion in the Gleam repo so it's on the radar.
- **Side project:** a glance-based type annotator library
  (`glimpse`/`glaze`/etc.). Not full Hindley-Milner — a directional
  propagation pass seeded from explicit annotations and dep signatures.
  Feasible as an independent effort; would benefit the whole Gleam
  tooling ecosystem, not just graded.

**Scope (once unblocked):**

- Effect variables become part of record type schemes.
- Construction sites generate binding constraints fed into the 0.7.0
  solver.
- Field-call sites look up the value's type and resolve the field's
  effect term directly.
- Hand-written field bounds (README's "Hand-written field bounds"
  idea) become the escape hatch for the residual cases, not the main
  mechanism.

**Estimate:** 2–3 weeks on top of a working type annotator. The
annotator itself is the long pole.

---

## Parallel, non-blocking

- **Engagement with the Gleam compiler team** on exposing typed AST —
  one-time contribution, benefits all Gleam analysis tools.
- **Ecosystem catalog growth** — add `.graded` entries for more common
  packages as they're encountered. Not a milestone, a maintenance
  thread.
- **Privacy / information-flow checking** (see README's Future work) —
  the next major direction after the effect checker is complete. Shares
  the graded modal type theory foundation; distinct enough to warrant
  its own design doc when the time comes.

---

## Summary table

| Milestone | What it closes | Blocker | Status |
|---|---|---|---|
| 0.6.0 | Field calls on same-function records | — | ✅ shipped |
| 0.7.0 | Nested higher-order polymorphism | — | next |
| 3b | Full propagation through record types | Expression-level type info | blocked |
| Privacy | New checker on the same foundation | Dedicated design | future |
