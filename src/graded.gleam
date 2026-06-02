//// Effect checker for Gleam via sidecar `.graded` annotation files.
////
//// graded verifies that your Gleam functions respect their declared effect
//// budgets. Annotations live in `.graded` sidecar files alongside your source
//// — your Gleam code stays clean.
////
//// ## Usage
////
//// ```sh
//// gleam run -m graded check [directory]   # enforce check annotations (default)
//// gleam run -m graded infer [directory]   # infer and write effect annotations
//// gleam run -m graded format [directory]  # normalize .graded file formatting
//// ```
////
//// ## Programmatic API
////
//// Use `run` to check a directory and get back a list of `CheckResult` values,
//// each containing any violations found per file. Use `run_infer` to infer
//// effects and write `.graded` files.
////

import argv
import filepath
import girard
import girard/types as girard_types
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/yielder
import graded/internal/annotation
import graded/internal/checker
import graded/internal/config
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/topo
import graded/internal/typeinfo
import graded/internal/types.{
  type CheckResult, type EffectAnnotation, type GradedFile, type QualifiedName,
  type Violation, type Warning, AnnotationLine, CheckResult, EffectAnnotation,
  GradedFile, QualifiedName,
}
import simplifile
import stdin

/// Errors that can occur during checking, inference, or formatting.
pub type GradedError {
  /// Could not read the source directory.
  DirectoryReadError(path: String, cause: simplifile.FileError)
  /// Could not read a source or annotation file.
  FileReadError(path: String, cause: simplifile.FileError)
  /// Could not write an annotation file.
  FileWriteError(path: String, cause: simplifile.FileError)
  /// Could not create the output directory for annotation files.
  DirectoryCreateError(path: String, cause: simplifile.FileError)
  /// A `.gleam` source file could not be parsed.
  GleamParseError(path: String, cause: glance.Error)
  /// A `.graded` annotation file could not be parsed.
  GradedParseError(path: String, cause: annotation.ParseError)
  /// One or more `.graded` files are not formatted (returned by `run_format_check`).
  FormatCheckFailed(paths: List(String))
  /// The project's import graph contains a cycle. Gleam disallows circular
  /// imports at the language level, so this should be unreachable in
  /// practice — if it ever fires it indicates a bug in the dependency edge
  /// extraction rather than user code.
  CyclicImports(modules: List(String))
}

pub fn main() -> Nil {
  let arguments = argv.load().arguments
  case arguments {
    ["infer", ..rest] ->
      case run_infer(target_directory(rest)) {
        Ok(Nil) -> io.println("graded: inferred effects written")
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["format", "--stdin"] -> {
      let input = stdin.read_lines() |> yielder.to_list() |> string.join("")
      case annotation.parse_file(input) {
        Ok(file) -> io.print(annotation.format_sorted(file))
        Error(_) -> {
          io.println_error("graded: error: could not parse stdin")
          halt(1)
        }
      }
    }
    ["format", "--check", ..rest] ->
      case run_format_check(target_directory(rest)) {
        Ok(Nil) -> Nil
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["format", ..rest] ->
      case run_format(target_directory(rest)) {
        Ok(Nil) -> Nil
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["check", ..rest] -> run_check(target_directory(rest))
    _ -> run_check(target_directory(arguments))
  }
}

/// Run the checker on all .gleam files in a directory.
///
/// Reads the project's single spec file (default `<package_name>.graded`)
/// to find inferred public-API effects, `check` invariants, `external`
/// hints, and `type` field annotations, then reports violations per source
/// file.
pub fn run(directory: String) -> Result(List(CheckResult), GradedError) {
  let cfg = read_config(directory)
  let spec = read_spec(cfg.spec_file)
  let checks_by_module = checks_grouped_by_module(spec)

  use gleam_files <- result.try(find_gleam_files(directory))
  use parsed <- result.try(parse_all_files(gleam_files))
  let index = build_module_index(parsed, directory)
  let dep_registry = signatures.load_from_packages_dir("build/packages")
  let registry = signatures.merge(dep_registry, build_project_registry(index))
  let type_info = build_type_index(index)

  // Hand-written `type` lines (last) win over the inferred construction index.
  let kb_base =
    effects.load_knowledge_base("build/packages")
    |> enrich_with_path_deps()
    |> effects.with_inferred(effects.load_spec_effects_from_file(spec))
    |> effects.with_externals(annotation.extract_externals(spec))
  let knowledge_base =
    kb_base
    |> effects.with_inferred_type_fields(build_constructor_field_index(
      index,
      kb_base,
    ))
    |> effects.with_type_fields(annotation.extract_type_fields(spec))

  let results =
    list.map(parsed, fn(entry) {
      let #(gleam_path, module) = entry
      let module_path = extract.module_path_for_source(gleam_path, directory)
      let module_checks = case dict.get(checks_by_module, module_path) {
        Ok(list) -> list
        Error(_) -> []
      }
      check_one_file(
        gleam_path,
        module,
        module_checks,
        knowledge_base,
        registry,
        typeinfo.for_module(type_info, module_path),
      )
    })

  Ok(results)
}

/// Infer effects for all `.gleam` files in `directory`. Writes two outputs:
///
/// 1. **Per-module cache files** under `<cache_dir>/<module_path>.graded`,
///    containing the inferred effects of every function in the module
///    (public + private). Regenerated freely; not shipped.
///
/// 2. **One spec file** at `<spec_file>` containing the inferred effects of
///    every *public* function across all modules, plus any hand-written
///    `check`, `external effects`, or `type` annotations the user already
///    had in the spec file (those lines are preserved verbatim).
///
/// Walks the project's import graph in topological order so each module is
/// analysed after every other project module it imports — a single pass
/// resolves transitive chains of any depth.
pub fn run_infer(directory: String) -> Result(Nil, GradedError) {
  let cfg = read_config(directory)
  let spec = read_spec(cfg.spec_file)

  use gleam_files <- result.try(find_gleam_files(directory))
  use parsed <- result.try(parse_all_files(gleam_files))
  let index = build_module_index(parsed, directory)

  let kb_base =
    effects.load_knowledge_base("build/packages")
    |> enrich_with_path_deps()
    |> effects.with_externals(annotation.extract_externals(spec))
  // Resolve constructor-field values against the same view `run` uses — catalog
  // + externals + the spec's *existing* inferred effects — so `infer` and
  // `check` agree on a field wired to a qualified project function, converging
  // across runs. The inferred effects are NOT seeded into `base_kb` below: the
  // topo loop recomputes them fresh, threading each module's result forward.
  let construction_kb =
    effects.with_inferred(kb_base, effects.load_spec_effects_from_file(spec))
  let base_kb =
    kb_base
    |> effects.with_inferred_type_fields(build_constructor_field_index(
      index,
      construction_kb,
    ))
    |> effects.with_type_fields(annotation.extract_type_fields(spec))

  let graph = build_dependency_graph(index)
  use sorted <- result.try(
    topo.sort(graph)
    |> result.map_error(fn(error) {
      let topo.Cycle(nodes:) = error
      CyclicImports(modules: nodes)
    }),
  )

  // Build a signature registry covering every project module so the
  // checker can do positional argument matching for cross-module
  // polymorphic calls.
  let dep_registry = signatures.load_from_packages_dir("build/packages")
  let registry = signatures.merge(dep_registry, build_project_registry(index))
  let type_info = build_type_index(index)

  use #(_kb, public_annotations) <- result.try(
    list.try_fold(sorted, #(base_kb, []), fn(state, module_path) {
      let #(kb, acc) = state
      case dict.get(index, module_path) {
        Error(_) -> Ok(state)
        Ok(#(_gleam_path, module)) -> {
          use #(new_kb, new_public) <- result.try(infer_one_module(
            module,
            module_path,
            cfg.cache_dir,
            kb,
            registry,
            typeinfo.for_module(type_info, module_path),
            typeinfo.fn_typed_for_module(type_info, module_path),
          ))
          // Prepend new_public so each iteration is O(|new_public|) instead
          // of O(|acc|); final order doesn't matter, merge_inferred keys by
          // function name.
          Ok(#(new_kb, list.append(new_public, acc)))
        }
      }
    }),
  )

  write_spec_file(cfg.spec_file, spec, public_annotations)
}

/// Format the project's spec file in place. The spec file is the single
/// source of truth for hand-written `check`/`external`/`type` lines and
/// the inferred public-API effects.
pub fn run_format(directory: String) -> Result(Nil, GradedError) {
  let cfg = read_config(directory)
  case format_one_spec(cfg.spec_file) {
    Error(_) -> Ok(Nil)
    Ok(formatted) ->
      simplifile.write(cfg.spec_file, formatted)
      |> result.map_error(FileWriteError(cfg.spec_file, _))
  }
}

/// Check that the project's spec file is already formatted. Returns error
/// with the file path if it isn't. Used by CI as `format --check`.
pub fn run_format_check(directory: String) -> Result(Nil, GradedError) {
  let cfg = read_config(directory)
  case format_one_spec(cfg.spec_file) {
    Error(_) -> Ok(Nil)
    Ok(formatted) ->
      case simplifile.read(cfg.spec_file) {
        Error(_) -> Ok(Nil)
        Ok(content) ->
          case content == formatted {
            True -> Ok(Nil)
            False -> Error(FormatCheckFailed(paths: [cfg.spec_file]))
          }
      }
  }
}

fn format_one_spec(spec_path: String) -> Result(String, GradedError) {
  use content <- result.try(
    simplifile.read(spec_path) |> result.map_error(FileReadError(spec_path, _)),
  )
  use file <- result.try(
    annotation.parse_file(content)
    |> result.map_error(GradedParseError(spec_path, _)),
  )
  Ok(annotation.format_sorted(file))
}

// PRIVATE

/// Parse every project source file once, returning `(path, parsed module)`
/// pairs. Used by `run_infer` so the topo sort can read each module's
/// imports without re-parsing on the inference pass.
fn parse_all_files(
  gleam_files: List(String),
) -> Result(List(#(String, glance.Module)), GradedError) {
  list.try_map(gleam_files, fn(gleam_path) {
    use module <- result.try(read_and_parse_gleam(gleam_path))
    Ok(#(gleam_path, module))
  })
}

/// Build a signature registry covering every project module. Used by
/// the checker's call-site substitution to resolve effect variables
/// when the caller passes positional (unlabeled) arguments.
fn build_project_registry(
  index: Dict(String, #(String, glance.Module)),
) -> SignatureRegistry {
  dict.fold(index, signatures.empty(), fn(acc, module_path, entry) {
    let #(_gleam_path, module) = entry
    signatures.merge(acc, signatures.from_glance_module(module_path, module))
  })
}

/// Stage C: derive `type Foo.field : [...]` annotations from constructor call
/// sites across the package. `Validator(to_error: io.println)` anywhere makes
/// `Validator.to_error` carry io.println's effects (unioned across all sites),
/// so a field call resolves without a hand-written annotation. Resolved via
/// girard's receiver typing at the use site; hand-written `type` lines still
/// win, since they are merged over these.
fn build_constructor_field_index(
  index: Dict(String, #(String, glance.Module)),
  knowledge_base: KnowledgeBase,
) -> List(#(#(String, String), types.TypeFieldEffect)) {
  // Global constructor-name -> type-name map across the whole package, so
  // cross-module constructors key by the type girard reports for a receiver.
  let constructor_to_type =
    dict.fold(index, dict.new(), fn(acc, _path, entry) {
      let #(_gleam_path, module) = entry
      dict.merge(acc, extract.build_constructor_type_map(module))
    })

  // Accumulate (type_name, field) -> effect, unioning across every site.
  dict.fold(index, dict.new(), fn(acc, _path, entry) {
    let #(_gleam_path, module) = entry
    let context = extract.build_import_context(module)
    extract.collect_constructor_bindings(module, context)
    |> list.fold(acc, fn(inner, binding) {
      accumulate_constructor_binding(
        inner,
        binding,
        constructor_to_type,
        knowledge_base,
      )
    })
  })
  |> dict.to_list()
}

/// Fold one constructor call's field bindings into the (type, field) -> effect
/// accumulator, unioning with any effect already recorded for that field.
fn accumulate_constructor_binding(
  acc: Dict(#(String, String), types.TypeFieldEffect),
  binding: #(String, Dict(String, types.ArgumentValue)),
  constructor_to_type: Dict(String, String),
  knowledge_base: KnowledgeBase,
) -> Dict(#(String, String), types.TypeFieldEffect) {
  let #(constructor, fields) = binding
  case dict.get(constructor_to_type, constructor) {
    Error(Nil) -> acc
    Ok(type_name) ->
      dict.fold(fields, acc, fn(inner, label, value) {
        let field_effect = field_effect_of(knowledge_base, value)
        let key = #(type_name, label)
        let merged = case dict.get(inner, key) {
          Ok(existing) -> merge_field_effect(existing, field_effect)
          Error(Nil) -> field_effect
        }
        dict.insert(inner, key, merged)
      })
  }
}

/// The effect a constructor field's value contributes. For a function reference
/// with effect variables, also capture the wired function's param bounds and
/// identity, so a field call can bind those variables to its arguments.
fn field_effect_of(
  knowledge_base: KnowledgeBase,
  value: types.ArgumentValue,
) -> types.TypeFieldEffect {
  let field_effects = effects.argument_value_effects(knowledge_base, value)
  let concrete = types.TypeFieldEffect(field_effects, [], None)
  case value {
    types.FunctionRef(name:) ->
      case types.has_variables(field_effects) {
        True ->
          types.TypeFieldEffect(
            field_effects,
            effects.lookup_param_bounds(knowledge_base, name),
            Some(name),
          )
        False -> concrete
      }
    _ -> concrete
  }
}

/// Union two field-effect contributions for the same field across sites. Keeps
/// the first polymorphic source — conflicting polymorphism across sites is rare,
/// and unbound variables collapse to `[Unknown]` at the call site.
fn merge_field_effect(
  existing: types.TypeFieldEffect,
  new: types.TypeFieldEffect,
) -> types.TypeFieldEffect {
  let #(bounds, source) = case existing.source {
    Some(_) -> #(existing.bounds, existing.source)
    None -> #(new.bounds, new.source)
  }
  types.TypeFieldEffect(
    types.union(existing.effects, new.effects),
    bounds,
    source,
  )
}

/// Run girard's whole-package type inference once over every project module
/// and fold the result into a `TypeInfo` (module path -> span start -> type).
/// girard is best-effort: a function it can't type contributes no expressions,
/// so the checker silently falls back to syntax-level resolution for it.
fn build_type_index(
  index: Dict(String, #(String, glance.Module)),
) -> typeinfo.TypeInfo {
  let options =
    girard.default_options()
    |> girard.with_resolver(build_girard_resolver(index))
  let entries =
    dict.to_list(index)
    |> list.map(fn(pair) {
      let #(module_path, #(_gleam_path, module)) = pair
      #(module_path, module)
    })
  let results = girard.annotate_package(entries, options) |> dict.to_list()
  let span_types =
    list.map(results, fn(pair) {
      let #(module_path, module_result) = pair
      let types =
        list.fold(
          module_result.annotated.expressions,
          dict.new(),
          fn(acc, annotation) {
            dict.insert(
              acc,
              #(annotation.span.start, annotation.span.end),
              annotation.type_,
            )
          },
        )
      #(module_path, types)
    })
  let fn_typed =
    list.filter_map(results, fn(pair) {
      let #(module_path, module_result) = pair
      case dict.get(index, module_path) {
        Ok(#(_gleam_path, module)) ->
          Ok(#(module_path, fn_typed_params_from_schemes(module_result, module)))
        Error(Nil) -> Error(Nil)
      }
    })
  typeinfo.from_modules(span_types, fn_typed)
}

/// From girard's inferred top-level signatures, the set of function-typed
/// parameter names for each function — including parameters with no syntactic
/// `fn(...)` annotation, which the glance-only detection misses. A parameter is
/// function-typed when its inferred type (positional in the function's `Fn`
/// type) is itself a `Fn`.
fn fn_typed_params_from_schemes(
  module_result: girard.ModuleResult,
  module: glance.Module,
) -> Dict(String, Set(String)) {
  let function_map =
    list.fold(module.functions, dict.new(), fn(acc, definition) {
      dict.insert(acc, definition.definition.name, definition.definition)
    })
  list.fold(module_result.annotated.functions, dict.new(), fn(acc, entry) {
    let #(name, scheme) = entry
    case scheme.type_, dict.get(function_map, name) {
      girard_types.Fn(argument_types, _return), Ok(function) ->
        dict.insert(acc, name, fn_typed_names(function, argument_types))
      _, _ -> acc
    }
  })
}

/// The names of `function`'s parameters whose inferred type (positional in
/// `argument_types`) is itself a `Fn`.
fn fn_typed_names(
  function: glance.Function,
  argument_types: List(girard_types.Type),
) -> Set(String) {
  // Positional mapping is only sound when girard's `Fn` arity matches glance's
  // parameter count. `list.zip` would silently truncate a mismatch, so skip the
  // function entirely rather than map parameters to the wrong types.
  use <- bool.guard(
    when: list.length(function.parameters) != list.length(argument_types),
    return: set.new(),
  )
  list.zip(function.parameters, argument_types)
  |> list.filter_map(fn(pair) {
    let #(parameter, argument_type) = pair
    case argument_type, parameter.name {
      girard_types.Fn(_, _), glance.Named(parameter_name) -> Ok(parameter_name)
      _, _ -> Error(Nil)
    }
  })
  |> set.from_list()
}

/// A girard `Resolver` that resolves graded's own project modules from `index`
/// first (so non-`src` layouts like `test/fixtures` work), then falls through
/// to girard's stock disk resolver for dependencies and stdlib under
/// `build/packages`.
fn build_girard_resolver(
  index: Dict(String, #(String, glance.Module)),
) -> fn(String) -> Result(String, Nil) {
  let disk = girard.disk_resolver()
  fn(module_path) {
    case dict.get(index, module_path) {
      Ok(#(gleam_path, _module)) ->
        simplifile.read(gleam_path) |> result.replace_error(Nil)
      Error(Nil) -> disk(module_path)
    }
  }
}

/// Build an index from dotted module name (`app/router`) to the parsed file.
/// This is the set of *project* modules — every module name in this dict is
/// a candidate dependency-graph node.
fn build_module_index(
  parsed: List(#(String, glance.Module)),
  directory: String,
) -> Dict(String, #(String, glance.Module)) {
  list.fold(parsed, dict.new(), fn(acc, entry) {
    let #(gleam_path, module) = entry
    let module_path = extract.module_path_for_source(gleam_path, directory)
    dict.insert(acc, module_path, #(gleam_path, module))
  })
}

/// For every project module, derive its set of project-internal imports.
/// Imports of stdlib/dep modules (anything not in `index`) are filtered out
/// — those are leaves with effects already resolved via the knowledge base
/// and don't belong in the topological sort.
fn build_dependency_graph(
  index: Dict(String, #(String, glance.Module)),
) -> Dict(String, Set(String)) {
  dict.map_values(index, fn(_module_path, entry) {
    let #(_path, module) = entry
    let context = extract.build_import_context(module)
    context.aliases
    |> dict.values()
    |> list.filter(fn(imported) { dict.has_key(index, imported) })
    |> set.from_list()
  })
}

/// Infer effects for a single module, write its cache file (with bare
/// names), and return the new knowledge base + the module's *public*
/// inferred annotations qualified with the module path. The caller
/// accumulates the public annotations for the eventual spec file write.
fn infer_one_module(
  module: glance.Module,
  module_path: String,
  cache_dir: String,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: Dict(#(Int, Int), girard_types.Type),
  girard_fn_typed: Dict(String, Set(String)),
) -> Result(#(KnowledgeBase, List(EffectAnnotation)), GradedError) {
  let inferred =
    checker.infer(
      module,
      knowledge_base,
      [],
      registry,
      module_types,
      girard_fn_typed,
    )

  let cache_path = filepath.join(cache_dir, module_path <> ".graded")

  // Skip the cache write when there's nothing to record. Saves an mkdir
  // syscall per stdlib-only module.
  use Nil <- result.try(case inferred {
    [] -> Ok(Nil)
    _ -> {
      let parent_directory = filepath.directory_name(cache_path)
      use Nil <- result.try(
        simplifile.create_directory_all(parent_directory)
        |> result.map_error(DirectoryCreateError(parent_directory, _)),
      )
      let cache_file = GradedFile(lines: list.map(inferred, AnnotationLine))
      write_graded_file(cache_path, cache_file)
    }
  })

  let inferred_dict =
    list.fold(inferred, dict.new(), fn(acc, ann) {
      dict.insert(
        acc,
        QualifiedName(module: module_path, function: ann.function),
        ann.effects,
      )
    })
  // Also thread polymorphic param bounds into the KB so later
  // modules in the topo-sort pass can bind variables at call sites
  // that target this module's functions.
  let params_dict =
    list.fold(inferred, dict.new(), fn(acc, ann) {
      case ann.params {
        [] -> acc
        _ ->
          dict.insert(
            acc,
            QualifiedName(module: module_path, function: ann.function),
            ann.params,
          )
      }
    })
  let new_kb =
    knowledge_base
    |> effects.with_inferred(inferred_dict)
    |> effects.with_inferred_params(params_dict)

  let public_names = public_function_names(module)
  let public_annotations =
    inferred
    |> list.filter(fn(ann) { set.contains(public_names, ann.function) })
    |> list.map(fn(ann) {
      EffectAnnotation(..ann, function: module_path <> "." <> ann.function)
    })

  Ok(#(new_kb, public_annotations))
}

/// Build a set of public function names from a parsed Gleam module.
fn public_function_names(module: glance.Module) -> set.Set(String) {
  list.fold(module.functions, set.new(), fn(acc, def) {
    case def.definition.publicity {
      glance.Public -> set.insert(acc, def.definition.name)
      glance.Private -> acc
    }
  })
}

/// Write the project's spec file. Reads the existing spec (if any),
/// preserves all `check`/`external`/`type` lines plus comments and blank
/// lines, replaces the inferred `effects` lines with the freshly inferred
/// public-function annotations, and writes the result back.
fn write_spec_file(
  spec_path: String,
  existing: GradedFile,
  inferred: List(EffectAnnotation),
) -> Result(Nil, GradedError) {
  let merged = annotation.merge_inferred(existing, inferred)

  // create_directory_all is a no-op when the parent already exists, so it's
  // safe to call unconditionally — and necessary when the user has
  // configured a non-default spec_file in a subdirectory.
  let parent = filepath.directory_name(spec_path)
  use Nil <- result.try(case parent == "" || parent == "." {
    True -> Ok(Nil)
    False ->
      simplifile.create_directory_all(parent)
      |> result.map_error(DirectoryCreateError(parent, _))
  })
  write_graded_file(spec_path, merged)
}

/// Group a parsed spec file's `check` annotations by their module path. Used
/// during `run` to hand each source file only the checks that apply to it.
/// The checker expects bare function names per module, so we strip the
/// module qualifier from the grouped annotations.
fn checks_grouped_by_module(
  spec: GradedFile,
) -> Dict(String, List(EffectAnnotation)) {
  list.fold(annotation.extract_checks(spec), dict.new(), fn(acc, ann) {
    case annotation.split_qualified_name(ann.function) {
      Error(_) -> acc
      Ok(#(module, function)) -> {
        let bare = EffectAnnotation(..ann, function:)
        let existing = case dict.get(acc, module) {
          Ok(list) -> list
          Error(_) -> []
        }
        dict.insert(acc, module, [bare, ..existing])
      }
    }
  })
}

/// Run the checker against one source file using the slice of `check`
/// annotations from the spec file that mention this file's module.
fn check_one_file(
  gleam_path: String,
  module: glance.Module,
  module_checks: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
  module_types: Dict(#(Int, Int), girard_types.Type),
) -> CheckResult {
  let #(violations, warnings) =
    checker.check(module, module_checks, knowledge_base, registry, module_types)
  CheckResult(file: gleam_path, violations:, warnings:)
}

/// Read the project's `[tools.graded]` config and return spec/cache paths
/// already resolved relative to the project root. The "project root" is
/// the directory containing `gleam.toml`:
///
/// - When `directory == "src"` (the production case), project root is `.`
///   and gleam.toml lives at `./gleam.toml`.
/// - Otherwise (tests against ad-hoc directories), the source directory
///   itself acts as the project root and gleam.toml is looked up there.
///
/// Resolved paths are returned in the same `GradedConfig` shape so callers
/// can use them as-is for I/O without further joining.
fn read_config(directory: String) -> config.GradedConfig {
  let project_root = case directory {
    "src" -> "."
    _ -> directory
  }
  let toml_path = filepath.join(project_root, "gleam.toml")
  let raw = case config.read(toml_path) {
    Ok(cfg) -> cfg
    Error(_) -> config.defaults_for(default_package_name(directory))
  }
  config.GradedConfig(
    package_name: raw.package_name,
    spec_file: resolve_path(project_root, raw.spec_file),
    cache_dir: resolve_path(project_root, raw.cache_dir),
  )
}

/// Join a path against a root, but leave it untouched if it's already
/// absolute (starts with `/`) or if the root is `.` (so production paths
/// stay short and unprefixed).
fn resolve_path(root: String, path: String) -> String {
  use <- bool.guard(
    when: string.starts_with(path, "/") || root == ".",
    return: path,
  )
  filepath.join(root, path)
}

fn default_package_name(directory: String) -> String {
  // Fallback used only when no gleam.toml is found. Best-effort — uses the
  // last path segment, then "graded" if the directory is empty or "/".
  case filepath.base_name(directory) {
    "" | "/" -> "graded"
    name -> name
  }
}

fn read_spec(spec_path: String) -> GradedFile {
  case simplifile.read(spec_path) {
    Error(_) -> GradedFile(lines: [])
    Ok(content) ->
      case annotation.parse_file(content) {
        Ok(file) -> file
        Error(_) -> GradedFile(lines: [])
      }
  }
}

/// For each path dependency declared in `gleam.toml`:
///
/// 1. Try to load its spec file (via the dep's own `[tools.graded]`
///    config, defaulting to `<package_name>.graded`) and fold its
///    annotations into the knowledge base. This is the fast, intended
///    path: the dep author already ran `graded infer`, committed the
///    spec file, and the consumer just reads it.
///
/// 2. If the dep has no spec file, fall back to inferring from source via
///    `infer_path_dep` so path deps without graded set up still work.
///    Cross-path-dep imports are not currently merged into a single graph
///    — each dep is processed sequentially.
fn enrich_with_path_deps(knowledge_base: KnowledgeBase) -> KnowledgeBase {
  let path_deps = effects.parse_path_dependencies("gleam.toml")
  list.fold(path_deps, knowledge_base, fn(kb, dep) {
    let #(name, dep_path) = dep
    let spec_file = case config.read(filepath.join(dep_path, "gleam.toml")) {
      Ok(cfg) -> cfg.spec_file
      Error(_) -> config.default_spec_file(name)
    }
    let spec_path = filepath.join(dep_path, spec_file)
    case simplifile.is_file(spec_path) {
      Ok(True) ->
        effects.with_inferred(kb, effects.load_spec_effects(spec_path))
      _ ->
        case infer_path_dep(dep_path, kb) {
          Error(Nil) -> kb
          Ok(inferred) -> effects.with_inferred(kb, inferred)
        }
    }
  })
}

/// Build the dependency-graph index for a single path dep, topo-sort it,
/// then infer every module in dependency order. Returns the union of all
/// inferred effects keyed by `QualifiedName` so the caller can fold them
/// into the global knowledge base. Errors are swallowed (returned as
/// `Error(Nil)`) to preserve the existing tolerance: a malformed dep
/// shouldn't break the whole project.
///
/// Exposed (pub) primarily so tests can exercise the topological-order path
/// inference on a temporary directory tree without going through
/// `gleam.toml` resolution. Production callers go through
/// `enrich_with_path_deps` which reads `gleam.toml` to discover dep paths.
pub fn infer_path_dep(
  dep_path: String,
  base_kb: KnowledgeBase,
) -> Result(Dict(QualifiedName, types.EffectSet), Nil) {
  let source_dir = dep_path <> "/src"
  let gleam_files = case simplifile.get_files(source_dir) {
    Ok(found) ->
      list.filter(found, fn(path) { string.ends_with(path, ".gleam") })
    Error(_) -> []
  }

  let entries =
    list.filter_map(gleam_files, fn(gleam_path) {
      use module <- result.try(
        read_and_parse_gleam(gleam_path) |> result.map_error(fn(_) { Nil }),
      )
      let module_path = extract.module_path_for_source(gleam_path, source_dir)
      // Path-dep checks come from the dep's spec file (loaded by
      // enrich_with_path_deps), not from per-module files. Inference here
      // only needs the parsed module.
      Ok(#(module_path, module, []))
    })

  let index =
    list.fold(entries, dict.new(), fn(acc, entry) {
      let #(module_path, module, checks) = entry
      dict.insert(acc, module_path, #(module, checks))
    })

  let graph =
    dict.map_values(index, fn(_module_path, entry) {
      let #(module, _checks) = entry
      let context = extract.build_import_context(module)
      context.aliases
      |> dict.values()
      |> list.filter(fn(imported) { dict.has_key(index, imported) })
      |> set.from_list()
    })

  use sorted <- result.try(topo.sort(graph) |> result.map_error(fn(_) { Nil }))
  let #(inferred, _final_kb) =
    list.fold(sorted, #(dict.new(), base_kb), fn(state, module_path) {
      infer_path_dep_module(state, module_path, index)
    })
  Ok(inferred)
}

fn infer_path_dep_module(
  state: #(Dict(QualifiedName, types.EffectSet), KnowledgeBase),
  module_path: String,
  index: Dict(String, #(glance.Module, List(types.EffectAnnotation))),
) -> #(Dict(QualifiedName, types.EffectSet), KnowledgeBase) {
  let #(acc, kb) = state
  case dict.get(index, module_path) {
    Error(_) -> #(acc, kb)
    Ok(#(module, checks)) -> {
      // Path-dep inference skips girard in v1 (cost/benefit): pass no types.
      let annotations =
        checker.infer(
          module,
          kb,
          checks,
          signatures.empty(),
          dict.new(),
          dict.new(),
        )
      let module_dict =
        list.fold(annotations, dict.new(), fn(d, annotation) {
          dict.insert(
            d,
            QualifiedName(module: module_path, function: annotation.function),
            annotation.effects,
          )
        })
      #(dict.merge(acc, module_dict), effects.with_inferred(kb, module_dict))
    }
  }
}

fn target_directory(arguments: List(String)) -> String {
  case arguments {
    [directory, ..] -> directory
    [] -> "src"
  }
}

fn run_check(directory: String) -> Nil {
  case run(directory) {
    Ok(results) -> {
      let violations =
        list.flat_map(results, fn(check_result) { check_result.violations })
      let warnings =
        list.flat_map(results, fn(check_result) { check_result.warnings })
      list.each(results, print_warnings)
      case warnings {
        [] -> Nil
        _ ->
          io.println(
            "graded: " <> int.to_string(list.length(warnings)) <> " warning(s)",
          )
      }
      case violations {
        [] -> io.println("graded: all checks passed")
        _ -> {
          list.each(results, print_violations)
          io.println(
            "\ngraded: "
            <> int.to_string(list.length(violations))
            <> " violation(s) found",
          )
          halt(1)
        }
      }
    }
    Error(error) -> {
      io.println_error("graded: error: " <> format_error(error))
      halt(1)
    }
  }
}

fn find_gleam_files(directory: String) -> Result(List(String), GradedError) {
  simplifile.get_files(directory)
  |> result.map_error(DirectoryReadError(directory, _))
  |> result.map(list.filter(_, fn(path) { string.ends_with(path, ".gleam") }))
}

fn read_and_parse_gleam(
  gleam_path: String,
) -> Result(glance.Module, GradedError) {
  use source <- result.try(
    simplifile.read(gleam_path)
    |> result.map_error(FileReadError(gleam_path, _)),
  )
  glance.module(source)
  |> result.map_error(GleamParseError(gleam_path, _))
}

fn write_graded_file(
  path: String,
  graded_file: GradedFile,
) -> Result(Nil, GradedError) {
  simplifile.write(path, annotation.format_file(graded_file))
  |> result.map_error(FileWriteError(path, _))
}

fn format_error(error: GradedError) -> String {
  case error {
    DirectoryReadError(path, _) -> "Could not read directory: " <> path
    FileReadError(path, _) -> "Could not read: " <> path
    FileWriteError(path, _) -> "Could not write: " <> path
    DirectoryCreateError(path, _) -> "Could not create directory: " <> path
    GleamParseError(path, _) -> "Could not parse: " <> path
    GradedParseError(path, _) -> "Parse error in .graded file for: " <> path
    FormatCheckFailed(paths:) ->
      "Unformatted .graded files:\n"
      <> string.join(list.map(paths, fn(path) { "  " <> path }), "\n")
    CyclicImports(modules:) ->
      "Cyclic project imports detected (this should be unreachable — Gleam disallows circular imports):\n"
      <> string.join(list.map(modules, fn(m) { "  " <> m }), "\n")
  }
}

fn print_violations(check_result: CheckResult) -> Nil {
  list.each(check_result.violations, fn(violation) {
    print_violation(check_result.file, violation)
  })
}

fn print_violation(file: String, violation: Violation) -> Nil {
  let base =
    file
    <> ": "
    <> violation.function
    <> " calls "
    <> violation.call.module
    <> "."
    <> violation.call.function
    <> " with effects "
    <> effects.format_effect_set(violation.actual)
    <> " but declared "
    <> effects.format_effect_set(violation.declared)
  // When the actual set still contains effect variables, the substitution
  // couldn't bind them (e.g. caller's own param has no declared bound).
  // Hint at the fix instead of letting the user puzzle over `[e_xxx]`.
  let hint = case types.has_variables(violation.actual) {
    True ->
      "\n  hint: actual effects contain unresolved variables; add a `check "
      <> violation.function
      <> "(<param>: [...])` bound, or pass a function reference / constructor"
      <> " whose effects are known"
    False -> ""
  }
  io.println(base <> hint)
}

fn print_warnings(check_result: CheckResult) -> Nil {
  list.each(check_result.warnings, fn(warning) {
    print_warning(check_result.file, warning)
  })
}

fn print_warning(file: String, warning: Warning) -> Nil {
  io.println(
    file
    <> ": warning: "
    <> warning.function
    <> " passes "
    <> warning.reference.module
    <> "."
    <> warning.reference.function
    <> " as a value — its effects "
    <> effects.format_effect_set(warning.effects)
    <> " won't be tracked",
  )
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
