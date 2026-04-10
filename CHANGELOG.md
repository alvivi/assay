# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.4.0]: https://github.com/alvivi/graded/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alvivi/graded/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alvivi/graded/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/alvivi/graded/releases/tag/v0.1.0
