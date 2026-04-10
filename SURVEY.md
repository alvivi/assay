# Prior Art Survey

This document summarizes research across four areas: Gleam tooling, effect systems, sidecar specification tools, and Granule/graded type theory.

## 1. Gleam Tooling Landscape

### glance (v6.0.0)

The primary Gleam parser library, written in Gleam by the Gleam team. Single entry point: `glance.module(src) -> Result(Module, Error)`.

**What it gives you:**
- Full module AST: imports, custom types, type aliases, constants, functions
- Functions: name, publicity, parameters (with labels and type annotations), return type, body statements
- 23 expression variants including Call, FieldAccess, Pipe, Case, Fn (anonymous), FnCapture (partial application)
- 11 pattern variants, 5 type annotation variants
- Source locations via `Span` (byte offsets)

**What it doesn't give you:**
- No type inference or resolution — untyped AST only
- No import resolution or cross-module graphs
- No call graph (but Call/FieldAccess nodes are sufficient to build one)

**Companion tools:**
- **glimpse** — package loader + type checker built on glance. Can recursively resolve imports. Type checking is "mostly not implemented yet." Early stage but directly relevant.
- **glance_printer** — pretty-prints glance ASTs back to source
- **glexer** — standalone Gleam lexer

### gleam export package-interface

`gleam export package-interface --out file.json` dumps fully resolved types for all **public** functions, types, and constants. Official decoder library: `gleam_package_interface` (v3.0.1).

Includes: parameter types with labels, return types, whether implementation is pure Gleam or FFI. Does **not** include private functions or function bodies.

### Gleam Compiler

Written in Rust. Not exposed as a reusable library. Pipeline: Source → Untyped AST → Typed AST → Erlang/JS codegen. The LSP has full typed AST info but only speaks JSON-RPC, not suitable for batch analysis.

### Existing Static Analysis

**None exist.** The compiler does exhaustiveness checking and unused variable warnings. No linters, no CodeQL/Semgrep support. graded would be the first significant static analysis tool for Gleam.

### Recommended Approach

Combine **glance** (source-level AST, call sites, control flow) with **package-interface** (typed signatures at module boundaries). The gap — types for private functions — is tolerable for effect checking since we only need to know *what functions are called*, not their inferred types.

---

## 2. Effect Systems in Practice

### Key Systems Surveyed

| System | Effect Representation | Polymorphism | Inference | Lesson |
|---|---|---|---|---|
| **Koka** | Row types | Row variables | Full H-M style | Gold standard but complex |
| **Eff** | Sets with subtyping | Limited | Constraint-based | Subset ordering aligns with our model |
| **Frank** | Implicit | Implicit (all args polymorphic) | Implicit | Elegant but hard to retrofit |
| **Haskell (effectful)** | Type-level list | Type variables | Manual | Pragmatism wins adoption |
| **OCaml 5** | Untyped at type level | N/A | None | Validates external effect tracking |
| **Java exceptions** | Declared sets | **None** | Partial | Cautionary tale |

### Effect Inference for Set-Based Systems

For graded's model (effects are sets, composition is union), inference is a forward dataflow problem:
- Walk the call graph bottom-up
- At each function, union the effects of all callees
- At branches, union both sides
- Check: `inferred_effects(f) ⊆ declared_effects(f)`

This is simple and decidable. The complication is effect polymorphism.

### Effect Polymorphism Is Critical

Without it, higher-order functions like `map` can't be annotated. Java checked exceptions failed precisely because of this. Options for graded:

1. **Effect variables**: `map : forall e. (List(a), fn(a) -e-> b) -e-> List(b)` — expressive, small syntax cost
2. **Transparent functions**: declare certain stdlib functions inherit callback effects — simpler but ad-hoc
3. **Monomorphic at call sites**: annotate each use — verbose

Recommendation: support effect variables. Instantiation is just set substitution.

### Practical Recommendations

- **~10-15 concrete effects** for Gleam: `{Pure, Http, Db, FileSystem, Process, Crypto, Time, Random, Stdin, Stdout}`
- **Require annotations at module boundaries, infer within**
- **Ship with stdlib annotations** — bootstrap problem otherwise
- **Never force completeness** — unannotated = unchecked

---

## 3. Sidecar Specification Tools

### Systems Surveyed

| Tool | Annotation Location | Reference Mechanism | Sync Strategy |
|---|---|---|---|
| **Liquid Haskell** | Inline comments `{-@ @-}` | By name (co-located) | Co-location helps |
| **Stainless** | Embedded Scala DSL | By code structure | Per-function verification |
| **JML / ACSL** | Inline comments | By adjacency | Co-location |
| **Python .pyi stubs** | Sidecar files | Filesystem mirroring + name | stubtest, CI |
| **CodeQL** | Separate query files | AST pattern matching | Re-extract each build |
| **Semgrep** | YAML rule files | Syntactic patterns | Re-scan each run |

### Key Design Lessons

**Filesystem mirroring works.** `src/foo.gleam` → `src/foo.graded`. No configuration needed. Proven by Python stubs.

**Reference by qualified name.** Module path + function name. Gleam has no overloading, so names are unambiguous within a module.

**Staleness is the #1 risk.** Every successful sidecar tool:
- Hard errors on missing references (annotation references a function that no longer exists)
- Warns on signature changes
- Enforces via CI

**Partial annotations are critical for adoption.** Unannotated modules are ignored entirely. This is how Python type stubs achieved adoption.

**Auto-generation of skeletons is essential.** Generate initial `.graded` files from Gleam source, then refine. Humans won't maintain sidecar files without tooling support.

**Inline comments don't scale.** JML, ACSL, and Liquid Haskell all suffer from annotation clutter. Sidecar files are the right choice.

**Per-function granularity is consensus.** Every successful spec tool operates at the function level.

**Incremental checking:** Module-level with content-addressed hashing (hash of `.gleam` + `.graded` + imported module interfaces). Good balance of simplicity and performance.

---

## 4. Granule and Graded Type Theory

### Granule Project Status

- ~27,400 lines of Haskell across 92 files. Checker alone is ~10,300 lines.
- Low activity (1 commit since Jan 2024) but research group is active (papers at ESOP 2024, CSL 2025).
- Requires Z3 at runtime via the Haskell `sbv` library.
- Pre-1.0 (v0.9.7.0).

### How Granule's Checker Works

1. **Bidirectional type checking** (`checkExpr` / `synthExpr`) walks the AST
2. When it encounters graded modalities, it generates **grade constraints** (equality or approximation)
3. Constraints accumulate during checking, then are **batch-solved via Z3**
4. For effects specifically, checking is done by **direct computation** in `Effects.hs` — no SMT needed

### Grading Algebras Supported

Nat (usage counting), Extended Nat, Q (rationals), Level (4-point security), Sec (Hi/Lo), LNL (Zero/One/Many), Set (effects), SetOp (dual), Interval, Product, Cartesian. Each algebra implements semiring operations and a preorder.

### Direct Reuse Is Impractical

The checker is tightly coupled to Granule's own AST, language features, and monolithic checker monad. Extracting the grade machinery would require gutting most of the checker. **Best used as an architectural reference only.**

**Gerty** (granule-project/gerty) is a smaller (~8,700 lines) implementation of graded modal dependent type theory. Its constraint infrastructure (`Constraints.hs` at 379 lines, `SymbolicGrades.hs` at 202 lines) is a cleaner reference.

### The Critical Simplification: Set Effects Don't Need SMT

From Granule's own `Effects.hs`:
- `effectMult` (composition): union the sets
- `effApproximates` (checking): subset test
- `effectUpperBound` (branches): union
- `isEffUnit` (purity): emptiness check

**All of these are trivial set operations.** No constraint solver, no SMT, no Z3. graded's first version needs none of that machinery.

### When Would You Need SMT?

Only when adding more complex algebras:
- **Linearity (naturals)**: `n + m <= k` with symbolic variables needs a solver
- **Privacy lattices**: large or parametric lattices benefit from SMT
- **Interval grades**: arithmetic inequality solving

Recommendation: start with direct computation for set effects. Add Z3 via SMT-LIB2 text protocol (language-agnostic) only when linearity or privacy checking is added.

### Key Papers

- **Orchard et al. (ICFP 2019)**: "Quantitative Program Reasoning with Graded Modal Types" — foundational Granule paper. Unifies effects and coeffects under graded modalities. Bidirectional checking with constraint generation.
- **Gaboardi et al. (ICFP 2016)**: "Combining Effects and Coeffects via Grading" — theoretical foundation. Effects = graded monads, coeffects = graded comonads.
- **Moon, Eades, Orchard (ESOP 2021)**: "Graded Modal Dependent Type Theory" — Gerty formalization.
- **QTT-TypeScript**: Demonstrates graded type checking can be done without Haskell or SMT, using direct constraint solving for simple semirings.

---

## Summary: What This Means for graded

### The core algorithm is simpler than expected

For set-based effect checking, the entire checker reduces to:

1. Parse `.graded` sidecar → extract `function_name: {Effect1, Effect2, ...}` annotations
2. Parse `.gleam` source via glance → extract function bodies and call sites
3. For each annotated function, walk the AST:
   - At each function call, look up the callee's declared effects (from `.graded` files or a built-in stdlib table)
   - Accumulate effects via set union
   - At branches (case/if), take the union of both branches
4. Check: accumulated effects ⊆ declared effects
5. Report violations with source spans

No SMT solver. No bidirectional type inference. No graded modalities. Just set operations over a call graph.

### Technology choices are clear

- **glance** for parsing Gleam source
- **gleam_package_interface** for typed signatures of dependencies
- **Filesystem mirroring** for `.graded` file placement
- **Qualified names** for referencing Gleam constructs
- **Effect variables** for polymorphism in annotations

### What to build first

1. A Gleam project that parses a `.gleam` file with glance and extracts its call graph
2. A parser for `.graded` annotation files (minimal grammar: function name → effect set)
3. The subset checker: inferred effects ⊆ declared effects
4. Stdlib effect annotations for `gleam/io`, `gleam/http`, `gleam/otp`
5. A `graded check` CLI command

### What to defer

- SMT/Z3 integration (not needed for set effects)
- Linearity checking (needs context splitting, usage tracking)
- Privacy lattices (needs lattice solver)
- Full bidirectional type checking (we're checking, not inferring)
- LLM integration (useful but not blocking)
