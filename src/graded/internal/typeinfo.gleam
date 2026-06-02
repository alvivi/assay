//// Per-expression type information sourced from girard, keyed so the checker
//// can ask "what is the nominal type of the receiver at this span?" without
//// knowing anything about girard's package-annotation shape.
////
//// Expressions are keyed by their full `#(start, end)` span. The start offset
//// alone is not unique — a receiver `v`, the field access `v.field`, and the
//// whole call `v.field(x)` all share a start offset but have different types,
//// so we need the end offset to pick out the receiver. A function girard could
//// not type contributes no expressions, so its spans are simply absent: every
//// lookup miss falls back to the syntax-level path, which is what makes girard
//// a pure enhancement layer (it can only ever upgrade an `[Unknown]`, never
//// change an already-resolved result).

import girard/types.{type Type, Named}
import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}

/// Inferred types for a whole package: module path -> (expression `#(start,
/// end)` span -> inferred type). Build with [`from_modules`](#from_modules);
/// query a single module's slice with [`for_module`](#for_module).
pub type TypeInfo {
  TypeInfo(by_module: Dict(String, Dict(#(Int, Int), Type)))
}

/// The empty type index — every lookup misses, so the checker behaves exactly
/// as it did before girard. Used when type inference is unavailable.
pub fn none() -> TypeInfo {
  TypeInfo(dict.new())
}

/// Build a `TypeInfo` from per-module span->type maps. The caller (graded's
/// orchestration) folds each girard `Annotated.expressions` list into a
/// `Dict(#(Int, Int), Type)` keyed by `#(span.start, span.end)`.
pub fn from_modules(
  modules: List(#(String, Dict(#(Int, Int), Type))),
) -> TypeInfo {
  TypeInfo(dict.from_list(modules))
}

/// The span->type slice for one module, or an empty map if the module was not
/// annotated (girard error, or not part of the package).
pub fn for_module(
  info: TypeInfo,
  module_path: String,
) -> Dict(#(Int, Int), Type) {
  case dict.get(info.by_module, module_path) {
    Ok(module_types) -> module_types
    Error(Nil) -> dict.new()
  }
}

/// The nominal type name of the expression spanning `#(start, end)`, if girard
/// inferred it as a `Named` type (a record / custom type — exactly what the
/// type-field registry is keyed by). `None` when the span is absent (girard
/// skipped the enclosing function) or the expression is not a named type.
pub fn receiver_type(
  module_types: Dict(#(Int, Int), Type),
  start: Int,
  end: Int,
) -> Option(String) {
  case dict.get(module_types, #(start, end)) {
    Ok(Named(_module, name, _arguments)) -> Some(name)
    _ -> None
  }
}
