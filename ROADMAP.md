# Roadmap

The big picture for closing graded's remaining analysis gaps. Ordered by
sequencing, not by size.

Current state: **milestone 3b is closed** — graded integrates
[girard](https://hexdocs.pm/girard), a Hindley-Milner type annotator, to resolve
field calls through real receiver types and to infer field effects from
construction sites (the hand-written `type` line is no longer required in the
common case). girard's inferred signatures also let graded detect higher-order
parameters that carry no `fn(...)` annotation, so an unannotated
`pub fn apply(f, x) { f(x) }` infers the polymorphic `apply(f: [f]) : [f]`
instead of `[Unknown]`. This subsumes 0.6.0's same-function value-flow hack and
removes the "expression-level type info isn't available" gap. **0.7.0** shipped
nested
higher-order effect unification. **0.6.0** shipped same-function value flow.
**0.5.0** shipped first-order effect polymorphism.

The gaps that remain are documented in [README.md](./README.md#limitations):

- Inferred field effects fall back to `[Unknown]` for values graded can't
  statically resolve (local function values, cross-module unlabelled positional
  constructor args); type-name keying is bare, so same-named types across
  modules are conflated.
- The label/position argument-matching heuristics remain (deliberately not
  retired — they drive polymorphic call-site substitution, a subsystem girard's
  expression types don't cleanly replace).

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
| 0.7.0 | Nested higher-order polymorphism | — | ✅ shipped |
| 3b | Field calls through record types (via girard) | ~~Expression-level type info~~ (unblocked by girard) | ✅ shipped |
| Privacy | New checker on the same foundation | Dedicated design | future |
