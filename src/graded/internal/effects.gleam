import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/annotation
import graded/internal/config
import graded/internal/types.{
  type EffectAnnotation, type EffectSet, type ExternalAnnotation,
  type ParamBound, type QualifiedName, type TypeFieldAnnotation, Check, Effects,
  FunctionExternal, ModuleExternal, Polymorphic, QualifiedName, Specific,
  Wildcard,
}
import simplifile
import tom

pub type EffectLookup {
  Known(EffectSet)
  Unknown
}

/// Bundles all effect knowledge: dependency + catalog, precomputed for fast lookup.
pub type KnowledgeBase {
  KnowledgeBase(
    all_effects: Dict(QualifiedName, EffectSet),
    param_bounds: Dict(QualifiedName, List(ParamBound)),
    type_fields: Dict(#(String, String), EffectSet),
    pure_modules: Set(String),
  )
}

/// Build a knowledge base by scanning dependency .graded files
/// and loading versioned catalog files from priv/catalog/.
pub fn load_knowledge_base(packages_directory: String) -> KnowledgeBase {
  let #(dep_effects, dep_params) = load_dependency_effects(packages_directory)
  let catalog_dir = find_catalog_directory()
  let #(cat_effects, cat_pure) = load_catalog(catalog_dir, "manifest.toml")
  KnowledgeBase(
    all_effects: dict.merge(dep_effects, cat_effects),
    param_bounds: dep_params,
    type_fields: dict.new(),
    pure_modules: cat_pure,
  )
}

/// Build a knowledge base from the catalog only (no dependency scanning).
pub fn empty_knowledge_base() -> KnowledgeBase {
  let catalog_dir = find_catalog_directory()
  let #(cat_effects, cat_pure) = load_catalog(catalog_dir, "manifest.toml")
  KnowledgeBase(
    all_effects: cat_effects,
    param_bounds: dict.new(),
    type_fields: dict.new(),
    pure_modules: cat_pure,
  )
}

/// Look up effects for a type's field.
pub fn lookup_type_field(
  knowledge_base: KnowledgeBase,
  type_name: String,
  field: String,
) -> EffectLookup {
  case dict.get(knowledge_base.type_fields, #(type_name, field)) {
    Ok(effect_set) -> Known(effect_set)
    Error(Nil) -> Unknown
  }
}

/// Merge type field annotations into a knowledge base.
pub fn with_type_fields(
  knowledge_base: KnowledgeBase,
  type_fields: List(TypeFieldAnnotation),
) -> KnowledgeBase {
  let merged =
    list.fold(
      type_fields,
      knowledge_base.type_fields,
      fn(accumulator, type_field) {
        dict.insert(
          accumulator,
          #(type_field.type_name, type_field.field),
          type_field.effects,
        )
      },
    )
  KnowledgeBase(..knowledge_base, type_fields: merged)
}

/// Merge external annotations into a knowledge base.
/// Module-level externals mark the whole module as pure.
/// Function-level externals are added to all_effects.
pub fn with_externals(
  knowledge_base: KnowledgeBase,
  externals: List(ExternalAnnotation),
) -> KnowledgeBase {
  let #(effect_map, pure_set) =
    list.fold(
      externals,
      #(knowledge_base.all_effects, knowledge_base.pure_modules),
      fn(accumulator, external_annotation) {
        let #(effect_map, pure_set) = accumulator
        case external_annotation.target {
          ModuleExternal -> #(
            effect_map,
            set.insert(pure_set, external_annotation.module),
          )
          FunctionExternal(function) -> #(
            dict.insert(
              effect_map,
              QualifiedName(external_annotation.module, function),
              external_annotation.effects,
            ),
            pure_set,
          )
        }
      },
    )
  KnowledgeBase(
    ..knowledge_base,
    all_effects: effect_map,
    pure_modules: pure_set,
  )
}

/// Look up the effect set for a qualified function name.
pub fn lookup(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectLookup {
  case dict.get(knowledge_base.all_effects, name) {
    Ok(effect_set) -> Known(effect_set)
    Error(Nil) ->
      case set.contains(knowledge_base.pure_modules, name.module) {
        True -> Known(types.empty())
        False -> Unknown
      }
  }
}

/// Look up effects, returning [Unknown] for unrecognized functions.
pub fn lookup_effects(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> EffectSet {
  case lookup(knowledge_base, name) {
    Known(effect_set) -> effect_set
    Unknown -> types.from_labels(["Unknown"])
  }
}

/// Format an effect set for display: [] for empty, [_] for wildcard, [A, B] sorted.
pub fn format_effect_set(effect_set: EffectSet) -> String {
  case effect_set {
    Wildcard -> "[_]"
    Specific(labels) ->
      case set.to_list(labels) |> list.sort(string.compare) {
        [] -> "[]"
        sorted -> "[" <> string.join(sorted, ", ") <> "]"
      }
    Polymorphic(labels, variables) -> {
      let sorted_labels = set.to_list(labels) |> list.sort(string.compare)
      let sorted_variables = set.to_list(variables) |> list.sort(string.compare)
      "["
      <> string.join(list.append(sorted_labels, sorted_variables), ", ")
      <> "]"
    }
  }
}

/// Parse gleam.toml to find path dependencies.
/// Returns a list of #(package_name, source_directory) pairs.
pub fn parse_path_dependencies(
  gleam_toml_path: String,
) -> List(#(String, String)) {
  let parsed = {
    use content <- result.try(
      simplifile.read(gleam_toml_path) |> result.map_error(fn(_) { Nil }),
    )
    use toml <- result.try(
      tom.parse(content) |> result.map_error(fn(_) { Nil }),
    )
    use deps <- result.try(
      tom.get_table(toml, ["dependencies"]) |> result.map_error(fn(_) { Nil }),
    )
    Ok(
      dict.fold(deps, [], fn(acc, name, value) {
        case value {
          tom.InlineTable(table) ->
            case tom.get_string(table, ["path"]) {
              Ok(path) -> [#(name, path), ..acc]
              Error(_) -> acc
            }
          _ -> acc
        }
      }),
    )
  }
  result.unwrap(parsed, [])
}

/// Load inferred effects from a package's spec file. The spec file uses
/// module-qualified function names (e.g. `myapp/router.handle`) so each
/// `effects` annotation maps directly to a `QualifiedName` without needing
/// to know which file it came from. Returns an empty dict when the spec
/// file is missing or unparseable.
pub fn load_spec_effects(spec_path: String) -> Dict(QualifiedName, EffectSet) {
  case read_spec_annotations(spec_path) {
    Error(_) -> dict.new()
    Ok(annotations) -> fold_spec_effects(annotations)
  }
}

/// Same as `load_spec_effects` but takes an already-parsed GradedFile,
/// avoiding a second read+parse when the caller already has the spec file
/// in hand.
pub fn load_spec_effects_from_file(
  file: types.GradedFile,
) -> Dict(QualifiedName, EffectSet) {
  fold_spec_effects(annotation.extract_annotations(file))
}

fn fold_spec_effects(
  annotations: List(EffectAnnotation),
) -> Dict(QualifiedName, EffectSet) {
  list.fold(annotations, dict.new(), fn(acc, ann) {
    case ann.kind {
      Effects ->
        case annotation.split_qualified_name(ann.function) {
          Ok(#(module, function)) ->
            dict.insert(acc, QualifiedName(module:, function:), ann.effects)
          Error(_) -> acc
        }
      Check -> acc
    }
  })
}

fn read_spec_annotations(
  spec_path: String,
) -> Result(List(EffectAnnotation), Nil) {
  use content <- result.try(
    simplifile.read(spec_path) |> result.replace_error(Nil),
  )
  use file <- result.try(
    annotation.parse_file(content) |> result.replace_error(Nil),
  )
  Ok(annotation.extract_annotations(file))
}

/// Merge inferred effects into a knowledge base.
/// Existing entries in the knowledge base take priority.
pub fn with_inferred(
  knowledge_base: KnowledgeBase,
  inferred: Dict(QualifiedName, EffectSet),
) -> KnowledgeBase {
  let merged = dict.merge(inferred, knowledge_base.all_effects)
  KnowledgeBase(..knowledge_base, all_effects: merged)
}

// PRIVATE

/// For each installed package, locate its spec file via the package's own
/// `[tools.graded]` config (defaulting to `<package_name>.graded`), parse
/// its qualified `effects` and `check` annotations, and fold them into the
/// global effect / param maps. Packages with no spec file are silently
/// skipped — same fail-soft semantics as the catalog and the old
/// per-module reader.
fn load_dependency_effects(
  packages_directory: String,
) -> #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))) {
  let entries = case simplifile.read_directory(packages_directory) {
    Ok(found) -> found
    Error(_) -> []
  }
  list.fold(entries, #(dict.new(), dict.new()), fn(maps, package_name) {
    let dep_root = packages_directory <> "/" <> package_name
    let spec_file = case config.read(dep_root <> "/gleam.toml") {
      Ok(cfg) -> cfg.spec_file
      Error(_) -> config.default_spec_file(package_name)
    }
    load_spec_into_maps(maps, dep_root <> "/" <> spec_file)
  })
}

fn load_spec_into_maps(
  maps: #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))),
  spec_path: String,
) -> #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))) {
  case read_spec_annotations(spec_path) {
    Error(_) -> maps
    Ok(annotations) -> list.fold(annotations, maps, fold_qualified_annotation)
  }
}

fn fold_qualified_annotation(
  accumulator: #(
    Dict(QualifiedName, EffectSet),
    Dict(QualifiedName, List(ParamBound)),
  ),
  ann: EffectAnnotation,
) -> #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))) {
  let #(effect_map, param_map) = accumulator
  case annotation.split_qualified_name(ann.function) {
    Error(_) -> accumulator
    Ok(#(module, function)) -> {
      let qualified_name = QualifiedName(module:, function:)
      case ann.kind {
        Effects -> #(
          dict.insert(effect_map, qualified_name, ann.effects),
          param_map,
        )
        Check ->
          case ann.params {
            [] -> accumulator
            params -> #(
              effect_map,
              dict.insert(param_map, qualified_name, params),
            )
          }
      }
    }
  }
}

fn find_catalog_directory() -> String {
  let installed = "build/packages/graded/priv/catalog"
  case simplifile.is_directory(installed) {
    Ok(True) -> installed
    _ -> "priv/catalog"
  }
}

fn load_catalog(
  catalog_dir: String,
  manifest_path: String,
) -> #(Dict(QualifiedName, EffectSet), Set(String)) {
  let installed_versions = parse_manifest_versions(manifest_path)
  let catalog_files = case simplifile.get_files(catalog_dir) {
    Ok(files) ->
      list.filter(files, fn(file) { string.ends_with(file, ".graded") })
    Error(_) -> []
  }

  let selected = resolve_catalog_files(catalog_files, installed_versions)

  let all_externals =
    list.flat_map(selected, fn(file_path) {
      case simplifile.read(file_path) {
        Error(_) -> []
        Ok(content) ->
          case annotation.parse_file(content) {
            Error(_) -> []
            Ok(graded_file) -> annotation.extract_externals(graded_file)
          }
      }
    })

  // Reuse the same external dispatch logic as with_externals
  let empty_kb =
    KnowledgeBase(
      all_effects: dict.new(),
      param_bounds: dict.new(),
      type_fields: dict.new(),
      pure_modules: set.new(),
    )
  let merged = with_externals(empty_kb, all_externals)
  #(merged.all_effects, merged.pure_modules)
}

fn resolve_catalog_files(
  catalog_files: List(String),
  installed_versions: Dict(String, String),
) -> List(String) {
  // Parse filenames: "path/to/gleam_stdlib@0.70.0.graded" → #("gleam_stdlib", #(0,70,0), path)
  let parsed =
    list.filter_map(catalog_files, fn(path) {
      let filename =
        path
        |> string.split("/")
        |> list.last()
        |> result.unwrap("")
        |> string.replace(".graded", "")
      case string.split(filename, "@") {
        [package, version] -> Ok(#(package, parse_semver(version), path))
        _ -> Error(Nil)
      }
    })

  // Group by package name
  let grouped =
    list.fold(parsed, dict.new(), fn(accumulator, entry) {
      let #(package, version, path) = entry
      let existing = dict.get(accumulator, package) |> result.unwrap([])
      dict.insert(accumulator, package, [#(version, path), ..existing])
    })

  // For each installed package, pick best catalog version
  dict.fold(grouped, [], fn(selected, package, versions) {
    case dict.get(installed_versions, package) {
      Error(Nil) -> selected
      Ok(installed_str) -> {
        let installed = parse_semver(installed_str)
        let best = pick_best_version(versions, installed)
        case best {
          Ok(path) -> [path, ..selected]
          Error(Nil) -> selected
        }
      }
    }
  })
}

pub fn pick_best_version(
  versions: List(#(#(Int, Int, Int), String)),
  installed: #(Int, Int, Int),
) -> Result(String, Nil) {
  // Pick highest version ≤ installed; if none, pick highest available
  let eligible =
    list.filter(versions, fn(version) { semver_lte(version.0, installed) })
    |> list.sort(fn(left, right) { compare_semver(right.0, left.0) })
  case eligible {
    [best, ..] -> Ok(best.1)
    [] ->
      // Fallback: use highest available catalog version
      case
        list.sort(versions, fn(left, right) { compare_semver(right.0, left.0) })
      {
        [best, ..] -> Ok(best.1)
        [] -> Error(Nil)
      }
  }
}

pub fn parse_semver(version: String) -> #(Int, Int, Int) {
  case string.split(version, ".") {
    [major, minor, patch] -> #(
      int.parse(major) |> result.unwrap(0),
      int.parse(minor) |> result.unwrap(0),
      int.parse(patch) |> result.unwrap(0),
    )
    [major, minor] -> #(
      int.parse(major) |> result.unwrap(0),
      int.parse(minor) |> result.unwrap(0),
      0,
    )
    _ -> #(0, 0, 0)
  }
}

pub fn semver_lte(left: #(Int, Int, Int), right: #(Int, Int, Int)) -> Bool {
  compare_semver(left, right) != order.Gt
}

pub fn compare_semver(
  left: #(Int, Int, Int),
  right: #(Int, Int, Int),
) -> order.Order {
  case int.compare(left.0, right.0) {
    order.Eq ->
      case int.compare(left.1, right.1) {
        order.Eq -> int.compare(left.2, right.2)
        other -> other
      }
    other -> other
  }
}

fn parse_manifest_versions(manifest_path: String) -> Dict(String, String) {
  let parsed = {
    use content <- result.try(
      simplifile.read(manifest_path) |> result.map_error(fn(_) { Nil }),
    )
    use toml <- result.try(
      tom.parse(content) |> result.map_error(fn(_) { Nil }),
    )
    use packages <- result.try(
      tom.get_array(toml, ["packages"]) |> result.map_error(fn(_) { Nil }),
    )
    Ok(
      list.fold(packages, dict.new(), fn(accumulator, package) {
        case package {
          tom.InlineTable(table) ->
            case
              tom.get_string(table, ["name"]),
              tom.get_string(table, ["version"])
            {
              Ok(name), Ok(version) -> dict.insert(accumulator, name, version)
              _, _ -> accumulator
            }
          _ -> accumulator
        }
      }),
    )
  }
  result.unwrap(parsed, dict.new())
}
