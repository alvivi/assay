# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-04-21

### Added

- **Same-function value flow.** graded now tracks three kinds of local `let` bindings inside a function body and resolves calls through them:
  - **Function-ref aliases.** `let f = io.println; f("hi")` resolves to `gleam/io.println` instead of being treated as a local call. Transitive aliases (`let g = f`) resolve through the chain.
  - **Record construction.** `let v = Validator(to_error: io.println); v.to_error("oops")` resolves the field call to `io.println` directly — no per-type annotation needed for the common case of local construction. Both labelled (`Validator(to_error: ...)`) and positional (`Validator(...)`) construction work for same-module constructors; positional arguments are mapped to the constructor's declared labels.
  - **Shadowing.** Later `let`s correctly shadow earlier bindings; unrecognisable RHS expressions erase tracking so stale bindings don't leak forward.
- Block and closure bodies inherit the outer env but their own bindings don't leak out, matching Gleam's scoping.

### Notes

- Cross-function record construction (passing a record built in one function to another) remains opaque and still needs type-level annotations (`type myapp.Foo.field : [...]`). Pattern destructuring and `use`-bound names are deliberately treated as opaque.

## [0.5.0] - 2026-04-13

### Added

- **Effect polymorphism.** Effect variables (lowercase tokens inside brackets) let one signature express that a function propagates whatever effects its callback has:

  ```
  effects myapp/validation.validate_range(to_error: [e]) : [e]
  effects myapp.map_with_log(f: [e]) : [Stdout, e]
  ```

  `graded infer` produces polymorphic signatures automatically when a function calls a parameter annotated with a `fn(...) -> ...` type. The variable is named after the parameter.
- **Call-site substitution.** At each call site, effect variables bind to the concrete effects of the argument passed: a function reference resolves via the knowledge base, a type constructor is pure, the caller's own bounded parameter uses that bound's effects, and anything else falls back to `[Unknown]`. Works with both labeled (`validate_range(42, to_error: OutOfRange)`) and positional (`validate_range(42, OutOfRange)`) arguments. Covers cross-module calls, same-module local helpers, and calls into dependencies.
- **Dependency parameter positions.** graded now parses each `build/packages/<dep>/src/` tree with glance to learn dependency function signatures. Positional arguments to polymorphic dep functions resolve correctly without requiring labels.
- **Wildcard `[_]`.** Documented in the README's new Effect set syntax section. Wildcard is the top of the effect lattice — `[_]` as a declared budget permits any effects. Useful for entrypoints.

### Changed

- Violation messages now include a hint when the actual effects contain unresolved effect variables, suggesting a `check` bound or a concrete argument to bind against.

## [0.4.2] - 2026-04-12

### Fixed

- Added `gleam/dynamic/decode` to the `gleam_stdlib` catalog. Decoder combinators (`field`, `optional_field`, `string`, `int`, `list`, `dict`, `success`, etc.) are pure but were resolving as `[Unknown]`.
- `graded infer` now resolves cross-module type constructors as pure, matching the existing handling for unqualified constructors. Previously, calls like `types.NotFound(id)` from a sibling project module were marked `[Unknown]` because constructors aren't tracked in the knowledge base and the defining project module isn't in `pure_modules`. Constructors are pure by Gleam's syntactic rules — an uppercase-initial label after a `.` is always a type variant — so the qualified call, qualified pipe target, and qualified value-position branches in the extractor now short-circuit the same way the unqualified path does. Side-effecting expressions inside a constructor's argument list (e.g. `NotFound(io.println(x))`) still propagate.

## [0.4.1] - 2026-04-11

### Fixed

- `graded infer` now reads the spec file's `external effects` and `type` field declarations into the knowledge base before walking the import graph. Previously these were only consumed by `graded check`, so functions calling into a third-party module declared pure via `external effects` were still inferred as `[Unknown]`. The `check` pass passed but the inferred spec stayed noisy.

## [0.4.0] - 2026-04-10

### Added

- `[tools.graded]` config table in `gleam.toml`, with `spec_file` and `cache_dir` fields.
- `graded/internal/topo` module: standalone topological sort over a string-keyed dependency graph, with property and unit tests.

### Changed

- Project annotations have moved out of `priv/graded/`. Each Gleam package now has a single **spec file at the project root** (default name `<package_name>.graded`, configurable via `[tools.graded].spec_file` in `gleam.toml`) holding the public-API effects, `check` invariants, `external effects` hints, and `type` field annotations. Per-module inferred effects (public + private) live in **`build/.graded/`** as a regenerable build cache (configurable via `[tools.graded].cache_dir`). Both locations are read by `graded check` and written by `graded infer`.
- Function names in the spec file use the **module-qualified form**: `myapp.view`, `myapp/router.handle_request`. Slashes for the module path, dot before the function name (same convention as `external effects`). Cache files continue to use bare names because each one is implicitly scoped to a module by its file location.
- Type field annotations gained the same qualification: `type myapp.Handler.on_click : [Dom]`. The bare form (`type Handler.on_click : [Dom]`) remains valid in cache files.
- Library authors who want their effect annotations to ship to consumers must add their spec file to `included_files` in `gleam.toml`. Without this, downstream packages will not see the library's effects (and will fall back to `[Unknown]` for its functions, unless the catalog covers them).
- No automatic migration from the old layout. To migrate an existing project: move every `effects`/`check`/`external`/`type` line out of `priv/graded/<module>.graded` into `<package_name>.graded` at the project root, prefixing each function name with its module path. Then run `graded infer` and delete the old `priv/graded/` directory.

## [0.3.0] - 2026-04-07

### Added

- Cross-module effect propagation: inferred effects from sibling project modules are used when analyzing other modules in the same project. Two-pass inference resolves inter-module dependencies.

## [0.2.0] - 2026-04-07

### Added

- Catalog entry for `gleam_time` (all modules pure; `system_time`, `local_offset`, `utc_offset` marked `[Time]`).
- Catalog entry for `houdini` (fully pure).
- Automatic effect inference for path dependencies declared in `gleam.toml`. Functions from local path deps are now inferred from source instead of being marked `[Unknown]`.
- Path dependency inference loads existing `.graded` files for parameter bounds, improving accuracy for higher-order functions.
- Two-pass inference for path dependencies so cross-dep calls resolve correctly.

### Fixed

- Record constructors (`Ok`, `Error`, `Some`, custom types) no longer inferred as `[Unknown]`. Gleam constructors start with an uppercase letter and are always pure.

## [0.1.0] - 2025-04-04

### Added

- Effect checker for Gleam via sidecar `.graded` annotation files.
- `graded check` command to enforce `check` annotations.
- `graded infer` command to infer and write `effects` annotations.
- `graded format` command with `--check` and `--stdin` modes.
- Higher-order effect tracking with parameter bounds.
- Field call effect tracking with type-aware resolution.
- External effect declarations for third-party functions.
- Wildcard effect `[_]` as the universal top element.
- Warnings for function references passed as values with known effects.
- Versioned catalog system resolved against `manifest.toml`.
- Catalog entries for `gleam_stdlib`, `gleam_erlang`, `gleam_otp`, `gleam_http`, `gleam_httpc`, `gleam_json`, `gleam_regexp`, `gleam_yielder`, `gleam_crypto`, `lustre`, `lustre_http`, `simplifile`, `filepath`, `tom`.
