import assay/internal/annotation
import assay/internal/types.{
  type EffectAnnotation, type EffectSet, type ExternalAnnotation,
  type ParamBound, type QualifiedName, type TypeFieldAnnotation, Check, Effects,
  FunctionExternal, ModuleExternal, QualifiedName, Specific, Wildcard,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
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

/// Build a knowledge base by scanning dependency .assay files
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
  }
}

// PRIVATE

fn load_dependency_effects(
  packages_directory: String,
) -> #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))) {
  let entries = case simplifile.read_directory(packages_directory) {
    Ok(found) -> found
    Error(_) -> []
  }
  list.fold(entries, #(dict.new(), dict.new()), fn(maps, package_name) {
    let assay_directory =
      packages_directory <> "/" <> package_name <> "/priv/assay"
    let files = case simplifile.get_files(assay_directory) {
      Ok(found) -> found
      Error(_) -> []
    }
    list.fold(files, maps, fn(inner_maps, file_path) {
      case string.ends_with(file_path, ".assay") {
        True -> load_assay_file(inner_maps, file_path, assay_directory)
        False -> inner_maps
      }
    })
  })
}

fn load_assay_file(
  maps: #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))),
  file_path: String,
  assay_directory: String,
) -> #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))) {
  let parsed =
    simplifile.read(file_path)
    |> result.map_error(fn(_) { Nil })
    |> result.try(fn(content) {
      annotation.parse_file(content) |> result.map_error(fn(_) { Nil })
    })
  case parsed {
    Error(_) -> maps
    Ok(assay_file) -> {
      let module_path = file_path_to_module(file_path, assay_directory)
      let #(effect_map, param_map) = maps
      annotation.extract_annotations(assay_file)
      |> list.fold(#(effect_map, param_map), fn(accumulator, annotation) {
        fold_annotation(accumulator, annotation, module_path)
      })
    }
  }
}

fn fold_annotation(
  accumulator: #(
    Dict(QualifiedName, EffectSet),
    Dict(QualifiedName, List(ParamBound)),
  ),
  annotation: EffectAnnotation,
  module_path: String,
) -> #(Dict(QualifiedName, EffectSet), Dict(QualifiedName, List(ParamBound))) {
  let #(effect_map, param_map) = accumulator
  let qualified_name =
    QualifiedName(module: module_path, function: annotation.function)
  case annotation.kind {
    Effects -> #(
      dict.insert(effect_map, qualified_name, annotation.effects),
      param_map,
    )
    Check ->
      case annotation.params {
        [] -> accumulator
        params -> #(effect_map, dict.insert(param_map, qualified_name, params))
      }
  }
}

fn file_path_to_module(path: String, assay_directory: String) -> String {
  let prefix = assay_directory <> "/"
  let relative = case string.starts_with(path, prefix) {
    True -> string.drop_start(path, string.length(prefix))
    False -> path
  }
  string.replace(relative, ".assay", "")
}

fn find_catalog_directory() -> String {
  let installed = "build/packages/assay/priv/catalog"
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
      list.filter(files, fn(file) { string.ends_with(file, ".assay") })
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
            Ok(assay_file) -> annotation.extract_externals(assay_file)
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
  // Parse filenames: "path/to/gleam_stdlib@0.70.0.assay" → #("gleam_stdlib", #(0,70,0), path)
  let parsed =
    list.filter_map(catalog_files, fn(path) {
      let filename =
        path
        |> string.split("/")
        |> list.last()
        |> result.unwrap("")
        |> string.replace(".assay", "")
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

fn pick_best_version(
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

fn parse_semver(version: String) -> #(Int, Int, Int) {
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

fn semver_lte(left: #(Int, Int, Int), right: #(Int, Int, Int)) -> Bool {
  compare_semver(left, right) != order.Gt
}

fn compare_semver(
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
