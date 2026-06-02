//// Per-expression type information sourced from girard, keyed so the checker
//// can ask "what is the nominal type of the receiver at this span?" and "which
//// of this function's parameters are function-typed?" — without knowing
//// anything about girard's package-annotation shape.
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
import gleam/set.{type Set}

/// Inferred information for a whole package:
/// - `by_module`: module path -> (expression `#(start, end)` span -> type).
/// - `fn_typed`: module path -> (function name -> the set of its function-typed
///   parameter names, inferred from girard's signature — covers params with no
///   syntactic `fn(...)` annotation).
pub type TypeInfo {
  TypeInfo(
    by_module: Dict(String, Dict(#(Int, Int), Type)),
    fn_typed: Dict(String, Dict(String, Set(String))),
  )
}

/// The empty type index — every lookup misses, so the checker behaves exactly
/// as it did before girard. Used when type inference is unavailable.
pub fn none() -> TypeInfo {
  TypeInfo(dict.new(), dict.new())
}

/// Build a `TypeInfo` from per-module span->type maps and per-module
/// function->fn-typed-params maps.
pub fn from_modules(
  types_modules: List(#(String, Dict(#(Int, Int), Type))),
  fn_typed_modules: List(#(String, Dict(String, Set(String)))),
) -> TypeInfo {
  TypeInfo(
    by_module: dict.from_list(types_modules),
    fn_typed: dict.from_list(fn_typed_modules),
  )
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

/// The function->fn-typed-params slice for one module.
pub fn fn_typed_for_module(
  info: TypeInfo,
  module_path: String,
) -> Dict(String, Set(String)) {
  case dict.get(info.fn_typed, module_path) {
    Ok(module_fn_typed) -> module_fn_typed
    Error(Nil) -> dict.new()
  }
}

/// The fn-typed parameter names girard inferred for a single function, or an
/// empty set if girard did not type it (fall back to syntactic detection).
pub fn fn_typed_params(
  module_fn_typed: Dict(String, Set(String)),
  function: String,
) -> Set(String) {
  case dict.get(module_fn_typed, function) {
    Ok(names) -> names
    Error(Nil) -> set.new()
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
