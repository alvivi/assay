# Plan: assay Effect Checker — Lustre Purity Check Milestone

## Context

assay needs to go from research documents to a working prototype. The first concrete goal: check that Lustre `view` functions are pure (no side effects). This is narrow, high-value, and validates the entire approach end-to-end.

The theory is simple: effects are sets, composition is union, checking is subset inclusion. No SMT solver needed.

## Architecture

Six modules, no circular dependencies:

| Module | File | Responsibility |
|---|---|---|
| `types` | `src/assay/types.gleam` | Shared types: QualifiedName, EffectAnnotation, ResolvedCall, Violation, CheckResult |
| `annotation` | `src/assay/annotation.gleam` | Parse `.assay` sidecar files |
| `effects` | `src/assay/effects.gleam` | Knowledge base: known function → effect set |
| `extract` | `src/assay/extract.gleam` | Walk glance AST, resolve imports, extract calls |
| `checker` | `src/assay/checker.gleam` | Union effects, check subset, report violations |
| `assay` | `src/assay.gleam` | CLI entry point: find files, orchestrate, print results |

## .assay File Format (Minimal)

```
@effect view : {}
@effect update : {Http, Dom}
@effect handle_click : {Http}
```

`{}` means empty effect set — no side effects allowed. Any other label is an effect.

## Key Design Decisions

1. **`{}` = empty set.** A function declared `{}` must call nothing with effects.
2. **Three-tier lookup:** explicit effectful mapping → known-pure modules → `{Unknown}` (conservative default).
3. **Transitive local analysis.** If `view` calls a local helper `render_header`, analyze `render_header`'s body too. Cycle detection via visited set.
4. **Function references count.** `list.map(items, io.println)` — the reference to `io.println` contributes `{Stdout}` even though `list.map` itself is pure.
5. **Closures inherit.** `fn() { io.println("x") }` inside `view` contributes `{Stdout}` to `view`.
6. **Pipe handling.** Check whether glance desugars `|>` into Call nodes or keeps as BinaryOperator(Pipe). Handle both.

## Implementation Steps

### Step 1: Project Scaffold
- `gleam new assay` (or manually create gleam.toml, src/, test/)
- Add dependencies: `glance`, `simplifile`, `gleam_stdlib`, `gleeunit`
- Verify `gleam build` and `gleam test` work

### Step 2: Shared Types (`src/assay/types.gleam`)
- `QualifiedName` — module + function name (e.g., `"gleam/io"`, `"println"`)
- `EffectAnnotation` — function name + allowed effect set
- `ResolvedCall` — qualified name + source span
- `Violation` — function name, call site, expected effects, actual effect
- `CheckResult` — list of violations per file

### Step 3: Annotation Parser (`src/assay/annotation.gleam`)
- Parse `.assay` file line by line
- Match `@effect <name> : {<labels>}` pattern
- `{}` → empty set; `{Http, Db}` → set of those strings
- Skip blank lines and `--` comments
- Tests: valid annotations, empty set, multiple effects, comments, malformed input

### Step 4: Effect Knowledge Base (`src/assay/effects.gleam`)
- Map of qualified function names → effect sets
- Seed with: `gleam/io.*` → `{Stdout}`, `gleam/erlang/process.*` → `{Process}`, etc.
- List of known-pure modules: `gleam/list`, `gleam/string`, `gleam/int`, `gleam/option`, `gleam/result`, etc.
- Lookup function: returns explicit effect, or empty set for known-pure module, or `{Unknown}`
- Tests: known effectful, known pure, unknown

### Step 5: Call Extractor (`src/assay/extract.gleam`) — most complex module
- Walk glance AST recursively through all expression variants
- Resolve calls against import list:
  - `io.println(...)` → FieldAccess on alias → look up alias in imports → `gleam/io.println`
  - `println(...)` → Variable → look up in unqualified imports → `gleam/io.println`
  - `helper(...)` → Variable not in imports → local function call
- Handle: Call, FieldAccess, Pipe operator, function references (Variable pointing to imported function), Fn (closures), Case branches
- Return `List(ResolvedCall)` with qualified names and spans
- Tests: qualified calls, unqualified calls, pipe chains, closures, function references as arguments

### Step 6: Effect Checker (`src/assay/checker.gleam`)
- For each annotated function:
  1. Find it in the parsed module
  2. Extract all calls (step 5)
  3. For local calls, recursively extract their calls (with visited set for cycles)
  4. Look up each call's effects from knowledge base (step 4)
  5. Union all effects
  6. Check: actual ⊆ declared
  7. If violation: record the offending call site with span
- Return list of Violations
- Tests: pure function passes, effectful call in pure function fails, transitive violation, branching unions

### Step 7: CLI Entry Point (`src/assay.gleam`)
- Find all `.gleam` files in `src/` (recursive via simplifile)
- For each, check if a corresponding `.assay` file exists
- Parse both files
- Run checker
- Print results: file, function, violation details
- Exit code 0 if clean, 1 if violations

### Step 8: Integration Test
- Create a test fixture: a small Lustre-like module + `.assay` file
- Pure view that passes
- Impure view that fails (calls io.println)
- Run full pipeline end-to-end

## Verification

1. `gleam build` — compiles cleanly
2. `gleam test` — all unit tests pass
3. Create a test Gleam file + .assay file, run `gleam run -m assay` — reports violations correctly
4. A pure Lustre view function with `@effect view : {}` passes
5. A view that calls `io.println` or any effectful function is flagged with the call site location

## What's Deferred

- Effect polymorphism (effect variables in annotations)
- Package-interface integration for cross-package types
- Privacy / information flow checking (lattice algebra, data flow analysis)
- LLM agent integration
- Incremental checking / caching
