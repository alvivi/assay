import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import graded/internal/types.{
  type AnnotationKind, type EffectAnnotation, type EffectSet,
  type ExternalAnnotation, type GradedFile, type GradedLine, type ParamBound,
  type TypeFieldAnnotation, AnnotationLine, BlankLine, Check, CommentLine,
  EffectAnnotation, Effects, ExternalAnnotation, ExternalLine, FunctionExternal,
  GradedFile, ModuleExternal, ParamBound, Specific, TypeFieldAnnotation,
  TypeFieldLine, Wildcard,
}

pub type ParseError {
  InvalidLine(line_number: Int, content: String)
}

/// Parse an .graded file preserving full structure (comments, blanks, annotations).
pub fn parse_file(input: String) -> Result(GradedFile, ParseError) {
  input
  |> string.split("\n")
  |> list.index_map(fn(line, index) { #(index + 1, line) })
  |> list.try_map(fn(pair) {
    let #(line_number, line) = pair
    parse_structured_line(line, line_number)
  })
  |> result.map(fn(lines) { GradedFile(lines:) })
}

/// Parse an .graded file returning only the annotations (discards structure).
pub fn parse(input: String) -> Result(List(EffectAnnotation), ParseError) {
  use file <- result.try(parse_file(input))
  Ok(extract_annotations(file))
}

/// Extract all annotations from a parsed file.
pub fn extract_annotations(file: GradedFile) -> List(EffectAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      AnnotationLine(annotation) -> Ok(annotation)
      TypeFieldLine(_) -> Error(Nil)
      ExternalLine(_) -> Error(Nil)
      CommentLine(_) -> Error(Nil)
      BlankLine -> Error(Nil)
    }
  })
}

/// Extract only `check` annotations (enforced invariants).
pub fn extract_checks(file: GradedFile) -> List(EffectAnnotation) {
  extract_annotations(file)
  |> list.filter(fn(annotation) { annotation.kind == Check })
}

/// Render an EffectAnnotation back to its .graded line format.
pub fn format_annotation(annotation: EffectAnnotation) -> String {
  let prefix = case annotation.kind {
    Effects -> "effects"
    Check -> "check"
  }
  let params_string = case annotation.params {
    [] -> ""
    params ->
      "("
      <> string.join(
        list.map(params, fn(param) {
          param.name <> ": " <> format_effect_set(param.effects)
        }),
        ", ",
      )
      <> ")"
  }
  let effects_string = format_effect_set(annotation.effects)
  prefix
  <> " "
  <> annotation.function
  <> params_string
  <> " : "
  <> effects_string
}

/// Split a qualified function name like `myapp/router.handle` into its
/// module path and function name parts. Returns `Error(Nil)` for bare
/// names with no `.` separator.
///
/// The qualified format uses slashes within the module path
/// (`gleam/io`, `myapp/web/handlers`) and a `.` to separate the module
/// path from the function name. The split happens on the LAST `.` since
/// function names cannot contain dots.
pub fn split_qualified_name(qualified: String) -> Result(#(String, String), Nil) {
  case list.reverse(string.split(qualified, ".")) {
    [] -> Error(Nil)
    [_only_one] -> Error(Nil)
    [function, ..rest_reversed] -> {
      let module = string.join(list.reverse(rest_reversed), ".")
      case module == "" || function == "" {
        True -> Error(Nil)
        False -> Ok(#(module, function))
      }
    }
  }
}

/// Render a TypeFieldAnnotation back to its .graded line format. Includes
/// the module prefix when present (qualified form, used in spec files);
/// emits the bare form otherwise (cache files).
pub fn format_type_field(tf: TypeFieldAnnotation) -> String {
  let prefix = case tf.module {
    Some(module) -> module <> "."
    None -> ""
  }
  "type "
  <> prefix
  <> tf.type_name
  <> "."
  <> tf.field
  <> " : "
  <> format_effect_set(tf.effects)
}

/// Extract type field annotations from a parsed file.
pub fn extract_type_fields(file: GradedFile) -> List(TypeFieldAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      TypeFieldLine(tf) -> Ok(tf)
      _ -> Error(Nil)
    }
  })
}

/// Render an ExternalAnnotation back to its .graded line format.
fn external_sort_key(external_annotation: ExternalAnnotation) -> String {
  case external_annotation.target {
    ModuleExternal -> external_annotation.module
    FunctionExternal(function) -> external_annotation.module <> "." <> function
  }
}

pub fn format_external(external_annotation: ExternalAnnotation) -> String {
  let name = case external_annotation.target {
    ModuleExternal -> external_annotation.module
    FunctionExternal(function) -> external_annotation.module <> "." <> function
  }
  "external effects "
  <> name
  <> " : "
  <> format_effect_set(external_annotation.effects)
}

/// Extract external annotations from a parsed file.
pub fn extract_externals(file: GradedFile) -> List(ExternalAnnotation) {
  list.filter_map(file.lines, fn(line) {
    case line {
      ExternalLine(external_annotation) -> Ok(external_annotation)
      _ -> Error(Nil)
    }
  })
}

/// Render a full GradedFile back to a string, preserving structure.
pub fn format_file(file: GradedFile) -> String {
  file.lines
  |> list.map(fn(line) {
    case line {
      AnnotationLine(annotation) -> format_annotation(annotation)
      TypeFieldLine(tf) -> format_type_field(tf)
      ExternalLine(ext) -> format_external(ext)
      CommentLine(text) -> text
      BlankLine -> ""
    }
  })
  |> string.join("\n")
}

/// Merge inferred effects into an existing GradedFile, preserving structure.
///
/// - `check` lines: kept exactly where they are, unchanged
/// - Comments and blank lines: kept exactly where they are
/// - Existing `effects` lines: updated in-place with new effect set
/// - Stale `effects` lines (function no longer exists): removed
/// - New functions not yet in file: `effects` lines appended at end
pub fn merge_inferred(
  file: GradedFile,
  inferred: List(EffectAnnotation),
) -> GradedFile {
  let inferred_map =
    inferred
    |> list.map(fn(annotation) { #(annotation.function, annotation) })
    |> dict.from_list()

  let #(new_lines, placed) =
    list.fold(file.lines, #([], set.new()), fn(state, line) {
      let #(lines, placed_set) = state
      case line {
        AnnotationLine(annotation) ->
          case annotation.kind {
            Effects ->
              case dict.get(inferred_map, annotation.function) {
                Ok(new_annotation) -> #(
                  [AnnotationLine(new_annotation), ..lines],
                  set.insert(placed_set, annotation.function),
                )
                Error(Nil) -> #(lines, placed_set)
              }
            Check -> #([line, ..lines], placed_set)
          }
        TypeFieldLine(_) -> #([line, ..lines], placed_set)
        ExternalLine(_) -> #([line, ..lines], placed_set)
        CommentLine(_) -> #([line, ..lines], placed_set)
        BlankLine -> #([line, ..lines], placed_set)
      }
    })

  let remaining =
    inferred
    |> list.filter(fn(annotation) { !set.contains(placed, annotation.function) })
    |> list.map(AnnotationLine)

  GradedFile(lines: list.append(list.reverse(new_lines), remaining))
}

/// Format an GradedFile: normalize spacing, sort annotations, ensure trailing newline.
///
/// Output order:
/// 1. Leading comments (file header)
/// 2. `check` lines, sorted alphabetically by function name
/// 3. Blank line separator (if both check and effects lines exist)
/// 4. `effects` lines, sorted alphabetically by function name
/// 5. Single trailing newline
pub fn format_sorted(file: GradedFile) -> String {
  let comments = collect_comments(file.lines)
  let annotations = extract_annotations(file)

  let check_lines =
    annotations
    |> list.filter(fn(annotation) { annotation.kind == Check })
    |> list.sort(fn(left, right) {
      string.compare(left.function, right.function)
    })
    |> list.map(format_annotation)

  let effects_lines =
    annotations
    |> list.filter(fn(annotation) { annotation.kind == Effects })
    |> list.sort(fn(left, right) {
      string.compare(left.function, right.function)
    })
    |> list.map(format_annotation)

  let type_field_lines =
    extract_type_fields(file)
    |> list.sort(fn(left, right) {
      string.compare(
        left.type_name <> "." <> left.field,
        right.type_name <> "." <> right.field,
      )
    })
    |> list.map(format_type_field)

  let external_lines =
    extract_externals(file)
    |> list.sort(fn(left, right) {
      string.compare(external_sort_key(left), external_sort_key(right))
    })
    |> list.map(format_external)

  let sections = [
    comments,
    external_lines,
    type_field_lines,
    check_lines,
    effects_lines,
  ]

  sections
  |> list.filter(fn(section) { section != [] })
  |> list.map(fn(section) { string.join(section, "\n") })
  |> string.join("\n\n")
  |> fn(content) { content <> "\n" }
}

// PRIVATE

fn parse_structured_line(
  line: String,
  line_number: Int,
) -> Result(GradedLine, ParseError) {
  let trimmed = string.trim(line)
  case trimmed {
    "" -> Ok(BlankLine)
    "//" <> _ -> Ok(CommentLine(line))
    "effects " <> _ | "check " <> _ ->
      case parse_annotation_line(trimmed, line_number, line) {
        Ok(annotation) -> Ok(AnnotationLine(annotation))
        Error(parse_error) -> Error(parse_error)
      }
    "type " <> rest ->
      case parse_type_field_line(rest) {
        Ok(tf) -> Ok(TypeFieldLine(tf))
        Error(Nil) -> Error(InvalidLine(line_number, line))
      }
    "external effects " <> rest ->
      case parse_external_line(rest) {
        Ok(ext) -> Ok(ExternalLine(ext))
        Error(Nil) -> Error(InvalidLine(line_number, line))
      }
    _ -> Error(InvalidLine(line_number, line))
  }
}

fn parse_annotation_line(
  trimmed: String,
  line_number: Int,
  original: String,
) -> Result(EffectAnnotation, ParseError) {
  let #(kind, rest) = case trimmed {
    "effects " <> remaining -> #(Ok(Effects), remaining)
    "check " <> remaining -> #(Ok(Check), remaining)
    _ -> #(Error(Nil), "")
  }
  case kind {
    Error(Nil) -> Error(InvalidLine(line_number, original))
    Ok(parsed_kind) ->
      parse_annotation_rest(parsed_kind, rest, line_number, original)
  }
}

fn parse_annotation_rest(
  kind: AnnotationKind,
  rest: String,
  line_number: Int,
  original: String,
) -> Result(EffectAnnotation, ParseError) {
  let err = Error(InvalidLine(line_number, original))
  case string.split(rest, "(") {
    [] -> err
    [no_params] ->
      case parse_name_colon_effects(no_params) {
        Error(Nil) -> err
        Ok(#(name, effects)) ->
          Ok(EffectAnnotation(kind:, function: name, params: [], effects:))
      }

    // Has parameter bounds: "name(params) : effects"
    // Effect sets use '[]' not '()', so the first ')' closes the params list
    [name_part, ..rest_parts] ->
      parse_params_annotation(kind, name_part, rest_parts)
      |> result.replace_error(InvalidLine(line_number, original))
  }
}

// Parse a "name(params) : effects" annotation where params is a non-empty bound list.
fn parse_params_annotation(
  kind: AnnotationKind,
  name_part: String,
  rest_parts: List(String),
) -> Result(EffectAnnotation, Nil) {
  let name = string.trim(name_part)
  use <- bool.guard(name == "", Error(Nil))
  let rejoined = string.join(rest_parts, "(")
  case string.split(rejoined, ")") {
    [params_str, suffix, ..] ->
      parse_params_suffix(kind, name, params_str, suffix)
    _ -> Error(Nil)
  }
}

// Parse ") : [effects]" suffix and build the final annotation.
fn parse_params_suffix(
  kind: AnnotationKind,
  name: String,
  params_str: String,
  suffix: String,
) -> Result(EffectAnnotation, Nil) {
  let suffix_trimmed = string.trim(suffix)
  case string.starts_with(suffix_trimmed, ":") {
    False -> Error(Nil)
    True -> {
      let effects_str = string.trim(string.drop_start(suffix_trimmed, 1))
      case parse_effect_set(effects_str), parse_params_section(params_str) {
        Ok(effects), Ok(params) ->
          Ok(EffectAnnotation(kind:, function: name, params:, effects:))
        _, _ -> Error(Nil)
      }
    }
  }
}

// Parse a type field annotation. Two forms are accepted:
//
//   `TypeName.field_name : [effects]`               (bare — implicit module)
//   `module/path.TypeName.field_name : [effects]`   (qualified — spec file)
//
// The bare form is used in per-module cache files where the type's module is
// implied by the file's location. The qualified form is used in spec files
// where annotations from many modules share one file. The dot is the
// boundary between module path and `TypeName.field`; module path itself uses
// slashes (matching the `external effects` convention).
fn parse_type_field_line(rest: String) -> Result(TypeFieldAnnotation, Nil) {
  use #(qualified, effects) <- result.try(parse_name_colon_effects(rest))
  case string.split(qualified, ".") {
    [type_name, field] if type_name != "" && field != "" ->
      Ok(TypeFieldAnnotation(module: None, type_name:, field:, effects:))
    segments -> {
      // 3+ segments → qualified form. Last two are TypeName and field; the
      // rest joined back with `.` is the module path.
      let count = list.length(segments)
      use <- bool.guard(count < 3, Error(Nil))
      let module_segments = list.take(segments, count - 2)
      let trailing = list.drop(segments, count - 2)
      case trailing {
        [type_name, field] if type_name != "" && field != "" -> {
          let module = string.join(module_segments, ".")
          use <- bool.guard(module == "", Error(Nil))
          Ok(TypeFieldAnnotation(
            module: Some(module),
            type_name:,
            field:,
            effects:,
          ))
        }
        _ -> Error(Nil)
      }
    }
  }
}

// No "." → module-level external (e.g., `external effects gleam/list : []`)
// Has "." → function-level external (e.g., `external effects gleam/io.println : [Stdout]`)
fn parse_external_line(rest: String) -> Result(ExternalAnnotation, Nil) {
  use #(qualified, effects) <- result.try(parse_name_colon_effects(rest))
  let segments = string.split(qualified, ".")
  let len = list.length(segments)
  case len {
    1 ->
      Ok(ExternalAnnotation(module: qualified, target: ModuleExternal, effects:))
    _ -> {
      use function <- result.try(list.last(segments))
      let module = segments |> list.take(len - 1) |> string.join(".")
      Ok(ExternalAnnotation(
        module:,
        target: FunctionExternal(function),
        effects:,
      ))
    }
  }
}

fn parse_params_section(input: String) -> Result(List(ParamBound), Nil) {
  case string.trim(input) {
    "" -> Ok([])
    trimmed ->
      list.try_map(split_at_top_level_commas(trimmed), parse_single_param)
  }
}

fn parse_single_param(input: String) -> Result(ParamBound, Nil) {
  use #(name, effects) <- result.try(parse_name_colon_effects(input))
  Ok(ParamBound(name:, effects:))
}

// Shared helper: parse "name : [effects]" returning the trimmed name and effect set.
fn parse_name_colon_effects(input: String) -> Result(#(String, EffectSet), Nil) {
  case string.split(string.trim(input), ":") {
    [name_part, effects_part] -> {
      let name = string.trim(name_part)
      use <- bool.guard(when: name == "", return: Error(Nil))
      use effects <- result.try(parse_effect_set(string.trim(effects_part)))
      Ok(#(name, effects))
    }
    _ -> Error(Nil)
  }
}

// Split a string by ',' only at bracket depth 0 (ignoring commas inside [...]).
fn split_at_top_level_commas(input: String) -> List(String) {
  let #(segments, current, _depth) =
    list.fold(string.to_graphemes(input), #([], "", 0), fn(state, char) {
      let #(segs, cur, depth) = state
      case char {
        "," if depth == 0 -> #([cur, ..segs], "", depth)
        "[" -> #(segs, cur <> char, depth + 1)
        "]" -> #(segs, cur <> char, depth - 1)
        _ -> #(segs, cur <> char, depth)
      }
    })
  list.reverse([current, ..segments])
}

fn parse_effect_set(input: String) -> Result(EffectSet, Nil) {
  let trimmed = string.trim(input)
  let has_brackets =
    string.starts_with(trimmed, "[") && string.ends_with(trimmed, "]")
  use <- bool.guard(when: !has_brackets, return: Error(Nil))
  let inner =
    trimmed
    |> string.drop_start(1)
    |> string.drop_end(1)
    |> string.trim()
  case inner {
    "_" -> Ok(Wildcard)
    "" -> Ok(Specific(set.new()))
    _ ->
      inner
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(label) { label != "" })
      |> set.from_list()
      |> Specific
      |> Ok
  }
}

fn collect_comments(lines: List(GradedLine)) -> List(String) {
  list.filter_map(lines, fn(line) {
    case line {
      CommentLine(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn format_effect_set(effect_set: EffectSet) -> String {
  case effect_set {
    Wildcard -> "[_]"
    Specific(labels) ->
      case set.to_list(labels) |> list.sort(string.compare) {
        [] -> "[]"
        sorted -> "[" <> string.join(sorted, ", ") <> "]"
      }
  }
}
