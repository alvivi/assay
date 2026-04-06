import assay/annotation
import assay/types.{
  type ExternAnnotation, type ParamBound, type QualifiedName,
  type TypeFieldAnnotation, Effects, QualifiedName,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

pub type EffectLookup {
  Known(Set(String))
  Unknown
}

/// Bundles all effect knowledge: dependency + catalog, precomputed for fast lookup.
pub type KnowledgeBase {
  KnowledgeBase(
    all_effects: Dict(QualifiedName, Set(String)),
    param_bounds: Dict(QualifiedName, List(ParamBound)),
    type_fields: Dict(#(String, String), Set(String)),
    pure_modules: Set(String),
  )
}

/// Build a knowledge base by scanning dependency .assay files,
/// merged with the hardcoded catalog.
pub fn load_knowledge_base(packages_directory: String) -> KnowledgeBase {
  let #(dep_effects, dep_params) = load_dependency_effects(packages_directory)
  let catalog = catalog_effectful_functions()
  let merged = dict.merge(dep_effects, catalog)
  KnowledgeBase(
    all_effects: merged,
    param_bounds: dep_params,
    type_fields: dict.new(),
    pure_modules: catalog_pure_modules(),
  )
}

/// Build a knowledge base from the hardcoded catalog only.
pub fn empty_knowledge_base() -> KnowledgeBase {
  KnowledgeBase(
    all_effects: catalog_effectful_functions(),
    param_bounds: dict.new(),
    type_fields: dict.new(),
    pure_modules: catalog_pure_modules(),
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
    list.fold(type_fields, knowledge_base.type_fields, fn(acc, tf) {
      dict.insert(acc, #(tf.type_name, tf.field), tf.effects)
    })
  KnowledgeBase(..knowledge_base, type_fields: merged)
}

/// Merge extern annotations into a knowledge base.
pub fn with_externs(
  knowledge_base: KnowledgeBase,
  externs: List(ExternAnnotation),
) -> KnowledgeBase {
  let merged =
    list.fold(externs, knowledge_base.all_effects, fn(acc, ext) {
      dict.insert(acc, QualifiedName(ext.module, ext.function), ext.effects)
    })
  KnowledgeBase(..knowledge_base, all_effects: merged)
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
        True -> Known(set.new())
        False -> Unknown
      }
  }
}

/// Look up effects, returning [Unknown] for unrecognized functions.
pub fn lookup_effects(
  knowledge_base: KnowledgeBase,
  name: QualifiedName,
) -> Set(String) {
  case lookup(knowledge_base, name) {
    Known(effect_set) -> effect_set
    Unknown -> set.from_list(["Unknown"])
  }
}

/// Format an effect set for display: [] for empty, [A, B] sorted.
pub fn format_effect_set(effect_set: Set(String)) -> String {
  case set.to_list(effect_set) |> list.sort(string.compare) {
    [] -> "[]"
    labels -> "[" <> string.join(labels, ", ") <> "]"
  }
}

// PRIVATE

fn load_dependency_effects(
  packages_directory: String,
) -> #(Dict(QualifiedName, Set(String)), Dict(QualifiedName, List(ParamBound))) {
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
  maps: #(Dict(QualifiedName, Set(String)), Dict(QualifiedName, List(ParamBound))),
  file_path: String,
  assay_directory: String,
) -> #(Dict(QualifiedName, Set(String)), Dict(QualifiedName, List(ParamBound))) {
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
      |> list.fold(#(effect_map, param_map), fn(acc, ann) {
        let #(eff_map, par_map) = acc
        let qname = QualifiedName(module: module_path, function: ann.function)
        case ann.kind {
          Effects -> #(dict.insert(eff_map, qname, ann.effects), par_map)
          _ ->
            case ann.params {
              [] -> acc
              params -> #(eff_map, dict.insert(par_map, qname, params))
            }
        }
      })
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

fn catalog_effectful_functions() -> Dict(QualifiedName, Set(String)) {
  [
    #(QualifiedName("gleam/io", "println"), set.from_list(["Stdout"])),
    #(QualifiedName("gleam/io", "print"), set.from_list(["Stdout"])),
    #(QualifiedName("gleam/io", "debug"), set.from_list(["Stdout"])),
    #(QualifiedName("gleam/io", "print_error"), set.from_list(["Stderr"])),
    #(QualifiedName("gleam/io", "println_error"), set.from_list(["Stderr"])),
    #(QualifiedName("gleam/erlang/process", "send"), set.from_list(["Process"])),
    #(
      QualifiedName("gleam/erlang/process", "start"),
      set.from_list(["Process"]),
    ),
    #(
      QualifiedName("gleam/erlang/process", "sleep"),
      set.from_list(["Process"]),
    ),
    #(
      QualifiedName("gleam/erlang/process", "sleep_forever"),
      set.from_list(["Process"]),
    ),
    #(QualifiedName("lustre_http", "send"), set.from_list(["Http"])),
    #(QualifiedName("lustre_http", "get"), set.from_list(["Http"])),
    #(QualifiedName("lustre_http", "post"), set.from_list(["Http"])),
    #(QualifiedName("lustre/effect", "from"), set.from_list(["Effect"])),
    #(QualifiedName("lustre/effect", "batch"), set.from_list(["Effect"])),
  ]
  |> dict.from_list()
}

fn catalog_pure_modules() -> Set(String) {
  set.from_list([
    "gleam/list", "gleam/string", "gleam/int", "gleam/float", "gleam/bool",
    "gleam/option", "gleam/result", "gleam/dict", "gleam/set", "gleam/pair",
    "gleam/order", "gleam/bit_array", "gleam/bytes_tree", "gleam/string_tree",
    "gleam/regex", "gleam/uri", "gleam/dynamic", "lustre/element",
    "lustre/element/html", "lustre/element/svg", "lustre/attribute",
    "lustre/event",
  ])
}
