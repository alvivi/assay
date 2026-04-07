# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Catalog entry for `gleam_time` (all modules pure; `system_time`, `local_offset`, `utc_offset` marked `[Time]`).
- Catalog entry for `houdini` (fully pure).
- Automatic effect inference for path dependencies declared in `gleam.toml`. Functions from local path deps are now inferred from source instead of being marked `[Unknown]`.

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

[Unreleased]: https://github.com/alvivi/graded/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alvivi/graded/releases/tag/v0.1.0
