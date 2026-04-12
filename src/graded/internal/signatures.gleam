//// Package-interface-backed signature registry.
////
//// Loads type signatures from `gleam export package-interface` JSON output
//// so the checker can tell which function parameters are themselves
//// function-typed. This powers call-site effect substitution and
//// auto-inference of polymorphic signatures: knowing a parameter's type
//// is `fn(...) -> ...` lets graded bind an effect variable at the
//// definition site and substitute the caller's concrete argument at
//// each call site.
////
//// This module also exposes a glance-AST helper for detecting fn-typed
//// parameters on locally-defined functions without type info from the
//// package interface (e.g. private functions not in the exported JSON).

import glance.{type Function, FunctionType}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import graded/internal/types.{type QualifiedName, QualifiedName}

/// One parameter of a function's signature.
pub type ParameterInfo {
  ParameterInfo(position: Int, label: Option(String), is_fn_typed: Bool)
}

/// Maps qualified function names to their parameter signatures.
///
/// Only populated for functions whose signatures are known — public
/// functions covered by a package-interface export. Private functions
/// and third-party functions without an exported package interface are
/// absent; callers fall back to glance-AST inspection or treat the
/// parameters as opaque.
pub type SignatureRegistry {
  SignatureRegistry(signatures: Dict(QualifiedName, List(ParameterInfo)))
}

/// An empty registry — nothing known about any function's parameters.
pub fn empty() -> SignatureRegistry {
  SignatureRegistry(signatures: dict.new())
}

/// Merge two registries. On key conflict, `b` wins (so later-loaded
/// interfaces override earlier ones — useful when the project's own
/// interface is loaded after dependency interfaces).
pub fn merge(a: SignatureRegistry, b: SignatureRegistry) -> SignatureRegistry {
  SignatureRegistry(signatures: dict.merge(a.signatures, b.signatures))
}

/// Look up a function's parameter signatures.
pub fn lookup(
  registry: SignatureRegistry,
  name: QualifiedName,
) -> Option(List(ParameterInfo)) {
  case dict.get(registry.signatures, name) {
    Ok(params) -> Some(params)
    Error(Nil) -> None
  }
}

/// Names of a function's fn-typed parameters. Returns an empty set if
/// the function isn't in the registry (conservative: "we don't know").
pub fn fn_typed_param_names(
  registry: SignatureRegistry,
  name: QualifiedName,
) -> Set(String) {
  case lookup(registry, name) {
    None -> set.new()
    Some(params) ->
      params
      |> list.filter(fn(p) { p.is_fn_typed })
      |> list.filter_map(fn(p) { option.to_result(p.label, Nil) })
      |> set.from_list()
  }
}

// ──── JSON parsing ────

/// Parse a `gleam export package-interface` JSON string into a registry.
///
/// The JSON schema: top-level `{ "name": ..., "modules": { "<path>":
/// { "functions": { "<name>": { "parameters": [...], ... } } } } }`.
/// Each parameter has a `type.kind` — `"fn"` marks fn-typed parameters;
/// anything else (named, variable, tuple) is not.
pub fn load_from_json_string(
  json_string: String,
) -> Result(SignatureRegistry, json.DecodeError) {
  json.parse(json_string, package_interface_decoder())
}

/// Decoder for the minimal slice of package-interface JSON graded needs:
/// just enough to extract `(module.function) -> [ParameterInfo]`.
fn package_interface_decoder() -> decode.Decoder(SignatureRegistry) {
  use modules <- decode.field(
    "modules",
    decode.dict(decode.string, module_decoder()),
  )
  let signatures =
    modules
    |> dict.to_list()
    |> list.flat_map(fn(entry) {
      let #(module_path, functions) = entry
      functions
      |> dict.to_list()
      |> list.map(fn(fn_entry) {
        let #(fn_name, params) = fn_entry
        #(QualifiedName(module: module_path, function: fn_name), params)
      })
    })
    |> dict.from_list()
  decode.success(SignatureRegistry(signatures:))
}

/// Per-module slice: we only care about `functions` → name → parameter list.
fn module_decoder() -> decode.Decoder(Dict(String, List(ParameterInfo))) {
  use functions <- decode.optional_field(
    "functions",
    dict.new(),
    decode.dict(decode.string, function_decoder()),
  )
  decode.success(functions)
}

/// Per-function slice: just `parameters`.
fn function_decoder() -> decode.Decoder(List(ParameterInfo)) {
  use params <- decode.optional_field(
    "parameters",
    [],
    decode.list(parameter_decoder_indexed()),
  )
  decode.success(params)
}

/// Parameters have no intrinsic position in the JSON — it's their
/// list index. We decode each to a `(label, is_fn_typed)` pair and
/// assign positions after. To keep this as a single decoder, we
/// decode an intermediate tuple and reindex in `load_from_json_string`.
///
/// The trick: use `decode.list` above, then post-process. But gleam's
/// decode API doesn't expose indices mid-decode, so we decode each
/// parameter to a placeholder position=0, then renumber below.
fn parameter_decoder_indexed() -> decode.Decoder(ParameterInfo) {
  use label <- decode.field("label", decode.optional(decode.string))
  use type_kind <- decode.subfield(["type", "kind"], decode.string)
  decode.success(ParameterInfo(
    position: 0,
    label: label,
    is_fn_typed: type_kind == "fn",
  ))
}

/// After JSON decoding, parameter positions are all 0. This walks the
/// registry and renumbers each parameter list by its index.
pub fn renumber_positions(registry: SignatureRegistry) -> SignatureRegistry {
  let fixed =
    registry.signatures
    |> dict.map_values(fn(_name, params) {
      params
      |> list.index_map(fn(param, i) {
        ParameterInfo(
          position: i,
          label: param.label,
          is_fn_typed: param.is_fn_typed,
        )
      })
    })
  SignatureRegistry(signatures: fixed)
}

/// Convenience: parse JSON string and renumber positions. Prefer this
/// over `load_from_json_string` when you want positions populated.
pub fn from_json_string(
  json_string: String,
) -> Result(SignatureRegistry, json.DecodeError) {
  case load_from_json_string(json_string) {
    Ok(registry) -> Ok(renumber_positions(registry))
    Error(e) -> Error(e)
  }
}

// ──── Glance AST detection ────

/// Names of a local function's fn-typed parameters, detected from
/// glance AST type annotations. Returns names of parameters whose
/// type annotation is `fn(...) -> ...`.
///
/// Used for private functions and any function not covered by the
/// package-interface registry. Parameters without explicit type
/// annotations (or with non-function types) are omitted.
pub fn fn_typed_params_from_function(function: Function) -> Set(String) {
  function.parameters
  |> list.filter_map(fn(param) {
    case param.type_ {
      Some(FunctionType(_, _, _)) -> {
        case assignment_name(param.name) {
          Some(name) -> Ok(name)
          None -> Error(Nil)
        }
      }
      _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

fn assignment_name(name: glance.AssignmentName) -> Option(String) {
  case name {
    glance.Named(n) -> Some(n)
    glance.Discarded(_) -> None
  }
}
