//// Glance-backed signature registry.
////
//// Parses Gleam source with glance to learn which function parameters
//// are themselves function-typed. This powers call-site effect
//// substitution and auto-inference of polymorphic signatures: knowing a
//// parameter's type is `fn(...) -> ...` lets graded bind an effect
//// variable at the definition site and substitute the caller's
//// concrete argument at each call site.
////
//// Project modules are parsed during `run_infer` / `run`; dependency
//// modules are parsed from `build/packages/<dep>/src/` on demand.

import filepath
import glance.{type Function, type Module, FunctionType}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import graded/internal/types.{type QualifiedName, QualifiedName}
import simplifile

/// One parameter of a function's signature.
///
/// `label` is the Gleam argument label (e.g. `by` in `fn foo(by name: X)`).
/// `name` is the in-body parameter name when we have source access via
/// glance (`None` when the info was loaded from `gleam export
/// package-interface` JSON, which doesn't expose in-body names).
///
/// Auto-inferred param bounds key off the in-body name (because it's
/// what appears at call sites in the body), so matching at a call site
/// tries `name` before `label`.
pub type ParameterInfo {
  ParameterInfo(
    position: Int,
    label: Option(String),
    name: Option(String),
    is_fn_typed: Bool,
  )
}

/// Maps qualified function names to their parameter signatures.
///
/// Only populated for functions whose signatures are known — anything
/// parsed successfully from project or dependency source. Functions
/// absent from the registry fall back to glance-AST inspection at the
/// definition site, or are treated as opaque at call sites.
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

// ──── Glance AST → SignatureRegistry ────

/// Build a SignatureRegistry from a parsed project module. Used during
/// `run_infer` / `run` to give the checker position information for
/// every function in the project — which powers positional argument
/// matching at polymorphic call sites.
pub fn from_glance_module(
  module_path: String,
  module: Module,
) -> SignatureRegistry {
  let signatures =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      let function = definition.definition
      let params =
        list.index_map(function.parameters, fn(param, i) {
          ParameterInfo(
            position: i,
            label: param.label,
            name: assignment_name(param.name),
            is_fn_typed: case param.type_ {
              Some(FunctionType(_, _, _)) -> True
              _ -> False
            },
          )
        })
      dict.insert(
        acc,
        QualifiedName(module: module_path, function: function.name),
        params,
      )
    })
  SignatureRegistry(signatures:)
}

// ──── Glance AST detection ────

/// Names of a local function's fn-typed parameters, detected from
/// glance AST type annotations. Returns names of parameters whose
/// type annotation is `fn(...) -> ...`.
///
/// Parameters without explicit type annotations (or with non-function
/// types) are omitted.
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

// ──── Dependency loading via glance source parsing ────

/// Load signature registries for every dependency in `packages_dir`
/// by parsing each dep's `src/` directory with glance.
///
/// For each `<packages_dir>/<dep>/src/` subtree, walks every `.gleam`
/// file and folds it into the registry via `from_glance_module`,
/// using the path under `src/` as the module path (e.g.
/// `gleam_stdlib/src/gleam/list.gleam` → `gleam/list`).
///
/// Failures (missing `src/`, parse errors from version mismatches,
/// FFI-only Erlang packages) are silently skipped — affected deps
/// contribute no entries and calls into them fall back to label-only
/// argument matching at polymorphic call sites.
pub fn load_from_packages_dir(packages_dir: String) -> SignatureRegistry {
  case simplifile.read_directory(packages_dir) {
    Error(_) -> empty()
    Ok(entries) ->
      list.fold(entries, empty(), fn(acc, dep) {
        let src_dir = filepath.join(filepath.join(packages_dir, dep), "src")
        merge(acc, registry_from_source_dir(src_dir))
      })
  }
}

fn registry_from_source_dir(source_dir: String) -> SignatureRegistry {
  case simplifile.get_files(source_dir) {
    Error(_) -> empty()
    Ok(files) ->
      files
      |> list.filter(fn(p) { string.ends_with(p, ".gleam") })
      |> list.fold(empty(), fn(acc, gleam_path) {
        merge(acc, registry_from_gleam_file(gleam_path, source_dir))
      })
  }
}

fn registry_from_gleam_file(
  gleam_path: String,
  source_dir: String,
) -> SignatureRegistry {
  use source <- bool_or_default(simplifile.read(gleam_path), empty())
  use module <- bool_or_default(glance.module(source), empty())
  from_glance_module(module_path_for(gleam_path, source_dir), module)
}

/// Continuation-style result-or-default: runs `next` with the Ok value,
/// or returns `default` on Error. Lets callers chain reads/parses
/// without nested case expressions.
fn bool_or_default(result: Result(a, b), default: c, next: fn(a) -> c) -> c {
  case result {
    Ok(v) -> next(v)
    Error(_) -> default
  }
}

/// Compute the dotted module name for a gleam file under a dep's
/// `src/` directory. Mirrors `extract.module_path_for_source` but
/// kept inline to avoid a circular dep between modules.
fn module_path_for(gleam_path: String, source_dir: String) -> String {
  let prefix = source_dir <> "/"
  let relative = case string.starts_with(gleam_path, prefix) {
    True -> string.drop_start(gleam_path, string.length(prefix))
    False -> gleam_path
  }
  filepath.strip_extension(relative)
}
