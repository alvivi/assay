import assay/internal/annotation
import assay/internal/types.{
  AnnotationLine, BlankLine, Check, CommentLine, EffectAnnotation, Effects,
  ExternalAnnotation, ExternalLine, FunctionExternal, ParamBound, Specific,
  TypeFieldAnnotation, TypeFieldLine, Wildcard,
}
import generators
import gleam/dict
import gleam/list
import gleam/set
import gleeunit/should
import qcheck

// --- Parse ---

pub fn empty_effects_test() {
  let input = "effects view : []"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "view", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(Specific(set.new()))
}

pub fn single_effect_test() {
  let input = "effects update : [Http]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn multiple_effects_test() {
  let input = "effects update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(Specific(set.from_list(["Http", "Dom"])))
}

pub fn check_line_test() {
  let input = "check view : []"
  let assert Ok([
    EffectAnnotation(kind: Check, function: "view", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(Specific(set.new()))
}

pub fn check_with_effects_test() {
  let input = "check update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Check, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(Specific(set.from_list(["Http", "Dom"])))
}

pub fn mixed_file_test() {
  let input =
    "effects view : []
effects update : [Http, Dom]
check view : []"
  let assert Ok(annotations) = annotation.parse(input)
  annotations
  |> fn(a) {
    case a {
      [_, _, _] -> True
      _ -> False
    }
  }
  |> should.be_true()
}

pub fn comments_and_blanks_test() {
  let input =
    "// this is a comment

effects view : []

// another comment
check update : [Http]"
  let assert Ok(annotations) = annotation.parse(input)
  annotations
  |> fn(a) {
    case a {
      [_, _] -> True
      _ -> False
    }
  }
  |> should.be_true()
}

pub fn malformed_line_test() {
  let input = "bad line"
  let assert Error(_) = annotation.parse(input)
}

pub fn missing_brackets_test() {
  let input = "effects view : Http"
  let assert Error(_) = annotation.parse(input)
}

// --- parse_file structure preservation ---

pub fn parse_file_preserves_structure_test() {
  let input =
    "// header comment

effects view : []
check view : []

// footer"
  let assert Ok(file) = annotation.parse_file(input)
  case file.lines {
    [
      CommentLine(_),
      BlankLine,
      AnnotationLine(_),
      AnnotationLine(_),
      BlankLine,
      CommentLine(_),
    ] -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn extract_checks_test() {
  let input =
    "effects view : []
effects update : [Http]
check view : []
check handle_click : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  let checks = annotation.extract_checks(file)
  checks
  |> fn(c) {
    case c {
      [_, _] -> True
      _ -> False
    }
  }
  |> should.be_true()
}

// --- Format ---

pub fn format_annotation_effects_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "view",
      params: [],
      effects: Specific(set.new()),
    )
  annotation.format_annotation(ann) |> should.equal("effects view : []")
}

pub fn format_annotation_check_test() {
  let ann =
    EffectAnnotation(
      kind: Check,
      function: "update",
      params: [],
      effects: Specific(set.from_list(["Http", "Dom"])),
    )
  annotation.format_annotation(ann)
  |> should.equal("check update : [Dom, Http]")
}

// --- Parameter bounds ---

pub fn parse_single_param_bound_test() {
  let input = "effects apply(f: [Stdout]) : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.function |> should.equal("apply")
  ann.params
  |> should.equal([ParamBound("f", Specific(set.from_list(["Stdout"])))])
  ann.effects |> should.equal(Specific(set.new()))
}

pub fn parse_multiple_param_bounds_test() {
  let input = "effects transform(f: [], g: [Http]) : [Http]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params
  |> should.equal([
    ParamBound("f", Specific(set.new())),
    ParamBound("g", Specific(set.from_list(["Http"]))),
  ])
  ann.effects |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn parse_empty_param_list_is_invalid_test() {
  let input = "effects apply() : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params |> should.equal([])
}

pub fn parse_param_bound_check_test() {
  let input = "check safe_map(f: []) : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.kind |> should.equal(Check)
  ann.params |> should.equal([ParamBound("f", Specific(set.new()))])
}

pub fn format_annotation_with_params_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "apply",
      params: [ParamBound("f", Specific(set.from_list(["Stdout"])))],
      effects: Specific(set.new()),
    )
  annotation.format_annotation(ann)
  |> should.equal("effects apply(f: [Stdout]) : []")
}

pub fn format_annotation_with_multiple_params_test() {
  let ann =
    EffectAnnotation(
      kind: Check,
      function: "transform",
      params: [
        ParamBound("f", Specific(set.new())),
        ParamBound("g", Specific(set.from_list(["Http"]))),
      ],
      effects: Specific(set.from_list(["Http"])),
    )
  annotation.format_annotation(ann)
  |> should.equal("check transform(f: [], g: [Http]) : [Http]")
}

// --- Type field annotations ---

pub fn parse_type_field_test() {
  let input = "type Handler.on_click : [Dom]"
  let assert Ok(file) = annotation.parse_file(input)
  let tfs = annotation.extract_type_fields(file)
  let assert [tf] = tfs
  tf.type_name |> should.equal("Handler")
  tf.field |> should.equal("on_click")
  tf.effects |> should.equal(Specific(set.from_list(["Dom"])))
}

pub fn parse_type_field_multiple_effects_test() {
  let input = "type Request.send : [Http, Io]"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [tf] = annotation.extract_type_fields(file)
  tf.effects |> should.equal(Specific(set.from_list(["Http", "Io"])))
}

pub fn format_type_field_test() {
  let tf =
    TypeFieldAnnotation("Handler", "on_click", Specific(set.from_list(["Dom"])))
  annotation.format_type_field(tf)
  |> should.equal("type Handler.on_click : [Dom]")
}

// --- External annotations ---

pub fn parse_external_test() {
  let input = "external effects gleam/http/request.send : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/http/request")
  ext.target |> should.equal(FunctionExternal("send"))
  ext.effects |> should.equal(Specific(set.from_list(["Http"])))
}

pub fn parse_external_pure_test() {
  let input = "external effects gleam/json.decode : []"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/json")
  ext.target |> should.equal(FunctionExternal("decode"))
  ext.effects |> should.equal(Specific(set.new()))
}

pub fn format_external_test() {
  let ext =
    ExternalAnnotation(
      "gleam/httpc",
      FunctionExternal("send"),
      Specific(set.from_list(["Http"])),
    )
  annotation.format_external(ext)
  |> should.equal("external effects gleam/httpc.send : [Http]")
}

// --- Wildcard [_] ---

pub fn parse_wildcard_effects_test() {
  let input = "effects handler : [_]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.effects |> should.equal(Wildcard)
}

pub fn parse_wildcard_check_test() {
  let input = "check handler : [_]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.kind |> should.equal(Check)
  ann.effects |> should.equal(Wildcard)
}

pub fn parse_wildcard_param_bound_test() {
  let input = "effects apply(f: [_]) : [_]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params |> should.equal([ParamBound("f", Wildcard)])
  ann.effects |> should.equal(Wildcard)
}

pub fn format_wildcard_annotation_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "handler",
      params: [],
      effects: Wildcard,
    )
  annotation.format_annotation(ann) |> should.equal("effects handler : [_]")
}

// ──── Parse/Format Roundtrips (property) ────

pub fn annotation_roundtrip_test() {
  use a <- qcheck.given(generators.annotation_gen())
  let formatted = annotation.format_annotation(a)
  let assert Ok(parsed) = annotation.parse(formatted)
  parsed |> should.equal([a])
}

pub fn type_field_roundtrip_test() {
  use tf <- qcheck.given(generators.type_field_gen())
  let formatted = annotation.format_type_field(tf)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [TypeFieldLine(parsed)] = file.lines
  parsed |> should.equal(tf)
}

pub fn external_roundtrip_test() {
  use ext <- qcheck.given(generators.external_gen())
  let formatted = annotation.format_external(ext)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [ExternalLine(parsed)] = file.lines
  parsed |> should.equal(ext)
}

pub fn file_roundtrip_test() {
  use file <- qcheck.given(generators.assay_file_gen())
  let formatted = annotation.format_file(file)
  let assert Ok(parsed) = annotation.parse_file(formatted)
  parsed |> should.equal(file)
}

pub fn format_sorted_idempotence_test() {
  use file <- qcheck.given(generators.assay_file_gen())
  let s1 = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(s1)
  let s2 = annotation.format_sorted(parsed)
  s1 |> should.equal(s2)
}

// ──── merge_inferred Preservation (property) ────

pub fn merge_inferred_invariants_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(
      generators.assay_file_gen(),
      generators.inferred_list_gen(),
      fn(f, i) { #(f, i) },
    ),
  )
  let merged = annotation.merge_inferred(file, inferred)
  let merged_effects =
    annotation.extract_annotations(merged)
    |> list.filter(fn(a) { a.kind == Effects })

  // Non-effects lines preserved in order
  let non_effects = fn(f: types.AssayFile) {
    list.filter(f.lines, fn(line) {
      case line {
        AnnotationLine(a) -> a.kind != Effects
        _ -> True
      }
    })
  }
  non_effects(merged) |> should.equal(non_effects(file))

  // All inferred functions present
  let merged_names =
    merged_effects |> list.map(fn(a) { a.function }) |> set.from_list()
  list.each(inferred, fn(a) {
    set.contains(merged_names, a.function) |> should.be_true()
  })

  // No stale effects
  let inferred_names =
    inferred |> list.map(fn(a) { a.function }) |> set.from_list()
  list.each(merged_effects, fn(a) {
    set.contains(inferred_names, a.function) |> should.be_true()
  })

  // Effects match inferred values
  let inferred_map =
    inferred |> list.map(fn(a) { #(a.function, a) }) |> dict.from_list()
  list.each(merged_effects, fn(a) {
    let assert Ok(expected) = dict.get(inferred_map, a.function)
    a |> should.equal(expected)
  })
}
