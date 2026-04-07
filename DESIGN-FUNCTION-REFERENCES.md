# Design: Effect Propagation Through Function References

## Problem

assay performs syntax-level analysis. When a function reference is passed as a value to a higher-order function, its effects are lost:

```gleam
import gleam/io
import gleam/list

pub fn greet_all(names) {
  list.map(names, io.println)  // io.println's [Stdout] effects are not tracked
}
```

The checker sees `list.map` (pure) but doesn't know that `io.println` will be *called* by `list.map`. Inferred effects: `[]` -- unsound.

Inline closures work correctly because the call appears in the AST:

```gleam
list.map(names, fn(n) { io.println(n) })  // io.println call is visible -- [Stdout] tracked
```

As of the current implementation, assay emits a **warning** when a function reference with known non-pure effects is passed as a value. This document describes how to close the gap entirely.

## Proposed Approach

Use `gleam export package-interface` JSON to determine which parameters of called functions have function types. No type inference needed -- just signature lookup and argument position matching.

### Why This Works

We already have all the pieces except one:

| What we need | Where it comes from | Status |
|---|---|---|
| Which function is referenced | Extractor resolves `io.println` to `QualifiedName` | Done |
| What effects it has | Knowledge base lookup | Done |
| Which callee parameter is function-typed | **Package interface JSON** | **Missing** |

The missing piece is knowing that `list.map`'s second parameter has type `fn(a) -> b`. With that, when we see `list.map(items, io.println)`, we know argument 2 is a callback that will be invoked, so `io.println`'s effects should propagate.

## Package Interface Format

`gleam export package-interface --out interface.json` produces JSON with full type signatures for all public functions. Run during build, one per package.

### Function-typed parameter example

For a function `apply(items: List(a), f: fn(a) -> b) -> List(b)`:

```json
{
  "parameters": [
    {
      "label": null,
      "type": {
        "kind": "named",
        "name": "List",
        "package": "",
        "module": "gleam",
        "parameters": [{ "kind": "variable", "id": 0 }]
      }
    },
    {
      "label": null,
      "type": {
        "kind": "fn",
        "parameters": [{ "kind": "variable", "id": 0 }],
        "return": { "kind": "variable", "id": 1 }
      }
    }
  ],
  "return": {
    "kind": "named",
    "name": "List",
    "package": "",
    "module": "gleam",
    "parameters": [{ "kind": "variable", "id": 1 }]
  }
}
```

Key: a parameter with `"kind": "fn"` is function-typed. Any argument passed to that position will be called by the function.

### Type kinds in the JSON

| Kind | Meaning | Example |
|---|---|---|
| `"named"` | Named type with optional type parameters | `String`, `List(a)`, `Result(a, b)` |
| `"variable"` | Type variable (generic parameter) | `a`, `b` (represented by integer `id`) |
| `"fn"` | Function type | `fn(a) -> b` |
| `"tuple"` | Tuple type | `#(a, b)` |

## Algorithm

### At load time

1. For each dependency in `build/dev/erlang/*/`, run or read `gleam export package-interface`
2. Parse the JSON and build a **signature registry**: `Dict(QualifiedName, List(ParameterSignature))`
3. Each `ParameterSignature` records: position index, optional label, and whether the type has `kind: "fn"`

For the current project, export its own package-interface as well (or extract signatures from glance AST + type annotations).

### At check time (per function)

For each call site in the function body:

1. Look up the callee's signature in the registry
2. Match arguments to parameters (handling labeled arguments and pipes)
3. For each argument matched to a `kind: "fn"` parameter:
   - If the argument is a function reference (from `ExtractResult.references`): look up its effects and propagate
   - If the argument is a local variable name matching a param bound: use the bound's effects
   - If the argument is an inline closure: already handled (calls visible in AST)
4. Union all propagated effects into the call's effect set

### Argument-to-parameter matching

Three cases need handling:

**Positional arguments:**
```gleam
list.map(items, io.println)
// param 0 = items, param 1 = io.println
```

**Labeled arguments:**
```gleam
list.map(over: items, with: io.println)
// match by label, not position
```

**Pipe expressions:**
```gleam
items |> list.map(io.println)
// pipe inserts items as param 0, io.println becomes param 1
```

The extractor already handles pipes by extracting the pipe target as a resolved call. The argument matching would need to account for the implicit first argument.

## What This Does NOT Cover

### Local function signatures

Package interfaces only contain public function signatures from compiled packages. For functions defined in the **current module**, there's no JSON to read. Options:

1. **Use glance parameter type annotations.** If the local function has explicit type annotations on its parameters, we can check for function types. This is already partially done for field call resolution.
2. **Infer from the call graph.** If local function `helper` calls its parameter `f`, and we know `f`'s effects from a param bound, we can propagate. This already works via the existing param bounds system.
3. **Fall back to the warning.** For unannotated local higher-order functions, keep the current warning behavior.

### Private dependency functions

Package interfaces only expose **public** functions. If a dependency has a public function that delegates to an internal higher-order function, we can't see the internal signature. In practice this rarely matters -- the public API is what users call.

### Stored callbacks

If a function stores a callback in a data structure rather than calling it immediately, the approach assumes it will be called. This is a conservative (sound) over-approximation -- it may attribute effects that don't actually happen during the call.

```gleam
// EventHandler stores the callback, doesn't call it immediately
// Our approach would still propagate the callback's effects -- conservative but sound
let handler = event.on("click", io.println)
```

### Effect polymorphism in annotations

This approach propagates concrete effects at each call site. It does NOT add effect variables to the annotation syntax. The annotation:

```
effects map(f: [e]) : [e]
```

would be a separate feature. The package-interface approach makes it less urgent because effects propagate automatically at call sites without needing to declare polymorphic signatures.

## Data Flow

```
                    ┌─────────────────────┐
                    │  gleam export        │
                    │  package-interface   │
                    └─────────┬───────────┘
                              │ JSON
                              v
                    ┌─────────────────────┐
                    │  Signature Registry  │
                    │  Dict(QualifiedName, │
                    │    List(ParamSig))   │
                    └─────────┬───────────┘
                              │
   ┌──────────────┐           │           ┌──────────────────┐
   │  Extractor    │           │           │  Knowledge Base   │
   │  (references) ├───────────┼───────────┤  (effect lookup)  │
   └──────┬───────┘           │           └────────┬─────────┘
          │                   │                    │
          v                   v                    v
   ┌──────────────────────────────────────────────────────┐
   │                     Checker                          │
   │  For each call site:                                 │
   │    1. Look up callee signature                       │
   │    2. Match args to fn-typed params                  │
   │    3. Look up referenced function's effects          │
   │    4. Propagate effects to call site                 │
   └──────────────────────────────────────────────────────┘
```

## Implementation Steps

### Phase 1: Signature loading

1. Add a `SignatureRegistry` type to the `effects` module (or a new `signatures` module)
2. Parse package-interface JSON files from `build/dev/erlang/*/`
3. For each function, extract which parameter positions have `kind: "fn"` types
4. Store as `Dict(QualifiedName, List(#(Int, Option(String), Bool)))` -- (position, label, is_fn_typed)

Open question: should we run `gleam export package-interface` ourselves, or expect the user to have built the project first? The build directory should exist after `gleam build`.

### Phase 2: Argument matching

1. In the extractor, enrich call extraction to record **which argument is at which position** (currently arguments are walked but positions aren't tracked)
2. Handle labeled argument reordering
3. Handle pipe insertion (implicit first argument)

### Phase 3: Effect propagation

1. In the checker's `collect_effects`, for each resolved call:
   - Look up the callee's signature in the registry
   - For each argument matched to a `fn`-typed parameter:
     - If it's in `references` (a function reference), look up its effects
     - Propagate those effects to the call site
2. Remove (or downgrade) the warning for references whose effects are now tracked

### Phase 4: Current-module signatures

1. For public functions in the current module, use the project's own package-interface export
2. For private functions with type-annotated parameters, extract from glance AST
3. Unannotated parameters remain as warnings

## Complexity Estimate

| Component | Effort | Notes |
|---|---|---|
| JSON parsing + registry | Small | Standard JSON decoding, simple data structure |
| Argument position tracking | Medium | Extractor changes, labeled arg handling |
| Pipe argument insertion | Small | Already understood, just offset by 1 |
| Effect propagation in checker | Medium | Core logic, integrates with existing collect_effects |
| Current-module signatures | Small | Reuse package-interface for publics, glance for privates |
| Tests | Medium | Many edge cases: pipes, labels, captures, mixed args |

Total: a focused feature, not a type checker rewrite. No unification, no generalization, no exhaustiveness checking needed.

## References

- `gleam export package-interface --out FILE` -- CLI command to generate the JSON
- Package interface JSON lives at project root after export (user-specified path)
- Dependency build artifacts: `build/dev/erlang/{package}/`
- Current warning implementation: `extract.gleam` (`references` field), `checker.gleam` (`UntrackedEffectWarning`)
