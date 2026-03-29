# Theory behind assay

This document explains the mathematical foundations that assay uses to check effects in Gleam programs. No prior knowledge of type theory is assumed — we build up from simple ideas to the full picture.

## The core question

Given a function like this:

```gleam
pub fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text(model.title)]),
    html.p([], [html.text(model.body)]),
  ])
}
```

How do we *prove* that `view` is pure — that it performs no side effects?

A human can read the code and see it only calls `html.div`, `html.h1`, `html.p`, and `html.text`, which are all pure. But we want a machine to verify this, and to catch it when someone later adds `io.println("debugging")` inside `view`.

## Step 1: Effects as labels

The simplest model: assign each function a *label* describing what kind of side effect it performs.

```
io.println    → Stdout
io.print      → Stdout
process.send  → Process
http.get      → Http
list.map      → (nothing)
string.append → (nothing)
```

Functions with no label are pure. Functions with a label have that effect.

## Step 2: Effects as sets

A function might do more than one thing:

```gleam
pub fn log_and_notify(message: String) -> Nil {
  io.println(message)        // Stdout
  http.post(webhook, message) // Http
}
```

So each function has a *set* of effects, not a single label:

```
log_and_notify → {Stdout, Http}
view           → {}           (empty set = pure)
io.println     → {Stdout}
list.map       → {}
```

This is where set theory enters. The effect of a function is the **union** of the effects of everything it calls:

```
effects(log_and_notify) = effects(io.println) ∪ effects(http.post)
                        = {Stdout} ∪ {Http}
                        = {Stdout, Http}
```

## Step 3: Checking is subset inclusion

When you write an annotation like:

```
check view : []
```

You're declaring: "the effects of `view` must be a subset of the empty set."

The checker computes the actual effects by walking the function body, then checks:

```
actual_effects(view) ⊆ declared_effects(view)
```

If `view` calls `io.println`, then:

```
{Stdout} ⊆ {}  →  false  →  VIOLATION
```

If `view` only calls pure functions:

```
{} ⊆ {}  →  true  →  OK
```

A more permissive annotation works too:

```
check update : [Http, Dom]
```

This allows `update` to perform Http and Dom effects, but nothing else:

```
{Http} ⊆ {Http, Dom}  →  true  →  OK
{Http, Stdout} ⊆ {Http, Dom}  →  false  →  VIOLATION (Stdout not allowed)
```

## Step 4: Why this is a semiring

The mathematical structure underneath is a **semiring** — a set with two operations that interact nicely. For effects:

| Concept | Math | Effects meaning |
|---------|------|----------------|
| Elements | Sets of labels | `{}`, `{Stdout}`, `{Http, Db}` |
| "Addition" (⊕) | Set union (∪) | Combining effects: if f has {A} and g has {B}, calling both gives {A, B} |
| "Multiplication" (⊗) | Set intersection (∩) | Sequencing/composition (used in more advanced checking) |
| Zero (𝟎) | Empty set {} | No effects — pure |
| One (𝟏) | Universal set | All effects — unrestricted |

The semiring laws guarantee that effect composition is well-behaved:

- **Union is associative**: `(A ∪ B) ∪ C = A ∪ (B ∪ C)` — grouping doesn't matter
- **Union is commutative**: `A ∪ B = B ∪ A` ��� order doesn't matter
- **Empty set is identity**: `A ∪ {} = A` — calling a pure function adds no effects
- **Union is idempotent**: `A ∪ A = A` — calling the same effect twice doesn't create a new kind of effect

These aren't arbitrary axioms — they're exactly what you'd expect from combining effects. If function `f` does Http and function `g` does Http, calling both still only gives you Http as an effect *kind* (though it happens twice).

## Step 5: Transitive analysis

Consider:

```gleam
pub fn view(model: Model) -> Element(Msg) {
  render_header(model)
}

fn render_header(model: Model) -> Element(Msg) {
  io.println("rendering header")  // oops!
  html.h1([], [html.text(model.title)])
}
```

The effect of `view` isn't just its direct calls — it's everything reachable transitively:

```
effects(render_header) = {Stdout}
effects(view) = effects(render_header) = {Stdout}
```

Assay follows local function calls recursively, with cycle detection (via a visited set) to handle mutual recursion:

```gleam
fn a() { b() }
fn b() { a() }  // cycle — detected, not infinite loop
```

## Step 6: The bigger picture — graded modal types

Effects are just one instance of a more general framework called **graded modal type theory**. The key insight: many properties of programs can be described by "how much" or "what kind" of some resource is used, and these quantities form algebraic structures.

| Property | Algebra | Elements | "Zero" | Composition |
|----------|---------|----------|--------|-------------|
| **Effects** | Set semiring | `{Stdout, Http, ...}` | `{}` (pure) | Union |
| **Linearity** | Natural numbers | `0, 1, 2, ...` | `0` (unused) | Addition |
| **Privacy** | Lattice | `Public, Internal, Confidential, Secret` | `Public` | Join (max) |
| **Capabilities** | Set semiring | `{Read, Write, Admin}` | `{}` (no perms) | Union |

The checker algorithm is the same shape for all of these:

1. Walk the syntax tree
2. Collect the "grade" (effect set, usage count, privacy level, capability set) for each operation
3. Combine grades using the algebra's composition operation
4. Check that the result satisfies the declared constraint

This is what makes the theory powerful — you design the checker once, parameterized by the algebra, and get effect checking, linearity checking, privacy checking, and capability checking from the same infrastructure.

### Linearity example (future)

```
// Each database connection must be used exactly once
effects open_db : [Db]
linearity open_db : 1

pub fn handler(request: Request) -> Response {
  let conn = open_db()
  let result = query(conn, "SELECT ...")  // uses conn: count = 1 ✓
  // conn is not used again — good
  respond(result)
}
```

If someone accidentally uses `conn` twice:

```gleam
let result1 = query(conn, "SELECT ...")   // count = 1
let result2 = query(conn, "SELECT ...")   // count = 2, but declared 1 → VIOLATION
```

The algebra here is natural numbers: zero means unused, one means use exactly once, addition combines usages.

### Privacy example (future)

```
// user.email is Confidential, must not flow to Public outputs
privacy user_email : Confidential
privacy render_public_page : Public
```

The privacy levels form a *lattice*:

```
Secret > Confidential > Internal > Public
```

The rule: information at level L can only flow to contexts at level ≥ L. If `render_public_page` (Public) accesses `user.email` (Confidential):

```
Confidential ≤ Public  →  false  →  VIOLATION
```

## What assay implements today

Assay v0.1.0 implements the **effect checking** column:

- Effects are sets of string labels
- Composition is set union
- Checking is subset inclusion
- Transitive analysis follows local calls
- Knowledge base maps external functions to their effect sets

The annotation language is designed to extend to other algebras in the future — the `[...]` syntax works for sets (effects, capabilities) and could be extended with different bracket styles or keywords for naturals (linearity) and lattices (privacy).

## Further reading

### Accessible introductions

- **[What is a semiring?](https://en.wikipedia.org/wiki/Semiring)** — Wikipedia. Start here for the algebraic structure.
- **[Coeffects: a calculus of context-dependent computation](http://tomasp.net/coeffects/)** — Tomas Petricek's thesis site. Coeffects are the dual of effects; this is the friendliest introduction to the grading idea.
- **[Granule project homepage](https://granule-project.github.io/)** — The research language that implements graded modal types. Includes tutorials and examples.

### Core papers

- **Quantitative program reasoning with graded modal types** (Orchard, Liepelt, Eades, ICFP 2019) — The foundational paper for Granule. Introduces the graded modal type system that assay's theory is based on. [(PDF)](https://www.cs.kent.ac.uk/people/staff/dao7/publ/granule-icfp19.pdf)
- **Combining effects and coeffects via grading** (Gaboardi, Katsumata, Orchard, Breuvart, Uustalu, ICFP 2016) — Shows how effects and coeffects can live in the same system via graded modalities. [(PDF)](https://www.cs.kent.ac.uk/people/staff/dao7/publ/combining-effects-and-coeffects-icfp16.pdf)
- **Coeffects: Unified static analysis of context-dependence** (Petricek, Orchard, Mycroft, ICALP 2013) — The original coeffect paper. [(PDF)](http://tomasp.net/academic/papers/structural/coeffects-icalp.pdf)

### Background

- **[Algebraic effects for the rest of us](https://overreacted.io/algebraic-effects-for-the-rest-of-us/)** — Dan Abramov's blog post. Explains algebraic effects intuitively with JavaScript-like pseudocode. Not about graded types, but a good warm-up.
- **[Bounded linear logic](https://www.sciencedirect.com/science/article/pii/030439759290386T)** (Girard, Scedrov, Scott, 1992) — The origin of tracking "how many times" resources are used in logic. This is where linearity checking comes from.
- **[Types and programming languages](https://www.cis.upenn.edu/~bcpierce/tapl/)** (Pierce, 2002) — The standard textbook on type systems. Chapters on subtyping are relevant to understanding how effect subset checking relates to type theory.
