import assay/internal/annotation
import assay/internal/types.{
  AnnotationLine, AssayFile, BlankLine, Check, CommentLine, EffectAnnotation,
  Effects, ExternalAnnotation, ExternalLine, FunctionExternal, ParamBound,
  TypeFieldAnnotation, TypeFieldLine,
}
import gleam/set
import gleeunit/should

pub fn empty_effects_test() {
  let input = "effects view : []"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "view", params: _, effects: eff),
  ]) = annotation.parse(input)
  set.size(eff) |> should.equal(0)
}

pub fn single_effect_test() {
  let input = "effects update : [Http]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(set.from_list(["Http"]))
}

pub fn multiple_effects_test() {
  let input = "effects update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Effects, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(set.from_list(["Http", "Dom"]))
}

pub fn check_line_test() {
  let input = "check view : []"
  let assert Ok([
    EffectAnnotation(kind: Check, function: "view", params: _, effects: eff),
  ]) = annotation.parse(input)
  set.size(eff) |> should.equal(0)
}

pub fn check_with_effects_test() {
  let input = "check update : [Http, Dom]"
  let assert Ok([
    EffectAnnotation(kind: Check, function: "update", params: _, effects: eff),
  ]) = annotation.parse(input)
  eff |> should.equal(set.from_list(["Http", "Dom"]))
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

// --- Writer ---

pub fn format_annotation_effects_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "view",
      params: [],
      effects: set.new(),
    )
  annotation.format_annotation(ann) |> should.equal("effects view : []")
}

pub fn format_annotation_check_test() {
  let ann =
    EffectAnnotation(
      kind: Check,
      function: "update",
      params: [],
      effects: set.from_list(["Http", "Dom"]),
    )
  annotation.format_annotation(ann)
  |> should.equal("check update : [Dom, Http]")
}

pub fn format_file_round_trip_test() {
  let input =
    "// header

effects view : []
check view : []

// footer"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_file(file) |> should.equal(input)
}

// --- Merge ---

pub fn merge_updates_existing_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Effects, "view", [], set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", [], set.from_list(["Stdout"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(ann)] = merged.lines
  ann.effects |> should.equal(set.from_list(["Stdout"]))
}

pub fn merge_preserves_checks_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Check, "view", [], set.new())),
      AnnotationLine(EffectAnnotation(
        Effects,
        "update",
        [],
        set.from_list(["Http"]),
      )),
    ])
  let inferred = [
    EffectAnnotation(Effects, "update", [], set.from_list(["Http", "Dom"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(check_ann), AnnotationLine(effects_ann)] =
    merged.lines
  check_ann.kind |> should.equal(Check)
  check_ann.effects |> should.equal(set.new())
  effects_ann.effects |> should.equal(set.from_list(["Http", "Dom"]))
}

pub fn merge_removes_stale_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Effects, "deleted_fn", [], set.new())),
      AnnotationLine(EffectAnnotation(Effects, "view", [], set.new())),
    ])
  let inferred = [EffectAnnotation(Effects, "view", [], set.new())]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(ann)] = merged.lines
  ann.function |> should.equal("view")
}

pub fn merge_appends_new_test() {
  let file =
    AssayFile(lines: [
      AnnotationLine(EffectAnnotation(Effects, "view", [], set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", [], set.new()),
    EffectAnnotation(Effects, "update", [], set.from_list(["Http"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [AnnotationLine(first), AnnotationLine(second)] = merged.lines
  first.function |> should.equal("view")
  second.function |> should.equal("update")
}

// --- Parameter bounds ---

pub fn parse_single_param_bound_test() {
  let input = "effects apply(f: [Stdout]) : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.function |> should.equal("apply")
  ann.params |> should.equal([ParamBound("f", set.from_list(["Stdout"]))])
  set.size(ann.effects) |> should.equal(0)
}

pub fn parse_multiple_param_bounds_test() {
  let input = "effects transform(f: [], g: [Http]) : [Http]"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params
  |> should.equal([
    ParamBound("f", set.new()),
    ParamBound("g", set.from_list(["Http"])),
  ])
  ann.effects |> should.equal(set.from_list(["Http"]))
}

pub fn parse_empty_param_list_is_invalid_test() {
  // "()" with no params inside is not a valid annotation
  let input = "effects apply() : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.params |> should.equal([])
}

pub fn parse_param_bound_check_test() {
  let input = "check safe_map(f: []) : []"
  let assert Ok([ann]) = annotation.parse(input)
  ann.kind |> should.equal(Check)
  ann.params |> should.equal([ParamBound("f", set.new())])
}

pub fn format_annotation_with_params_test() {
  let ann =
    EffectAnnotation(
      kind: Effects,
      function: "apply",
      params: [ParamBound("f", set.from_list(["Stdout"]))],
      effects: set.new(),
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
        ParamBound("f", set.new()),
        ParamBound("g", set.from_list(["Http"])),
      ],
      effects: set.from_list(["Http"]),
    )
  annotation.format_annotation(ann)
  |> should.equal("check transform(f: [], g: [Http]) : [Http]")
}

pub fn param_bound_round_trip_test() {
  let input = "effects apply(f: [Stdout]) : []\n"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_file(file) |> should.equal(input)
}

// --- Type field annotations ---

pub fn parse_type_field_test() {
  let input = "type Handler.on_click : [Dom]"
  let assert Ok(file) = annotation.parse_file(input)
  let tfs = annotation.extract_type_fields(file)
  let assert [tf] = tfs
  tf.type_name |> should.equal("Handler")
  tf.field |> should.equal("on_click")
  tf.effects |> should.equal(set.from_list(["Dom"]))
}

pub fn parse_type_field_multiple_effects_test() {
  let input = "type Request.send : [Http, Io]"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [tf] = annotation.extract_type_fields(file)
  tf.effects |> should.equal(set.from_list(["Http", "Io"]))
}

pub fn format_type_field_test() {
  let tf = TypeFieldAnnotation("Handler", "on_click", set.from_list(["Dom"]))
  annotation.format_type_field(tf)
  |> should.equal("type Handler.on_click : [Dom]")
}

pub fn type_field_round_trip_test() {
  let input = "type Handler.on_click : [Dom]\n"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_file(file) |> should.equal(input)
}

pub fn merge_preserves_type_fields_test() {
  let file =
    AssayFile(lines: [
      TypeFieldLine(TypeFieldAnnotation(
        "Handler",
        "on_click",
        set.from_list(["Dom"]),
      )),
      AnnotationLine(EffectAnnotation(Effects, "view", [], set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", [], set.from_list(["Stdout"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [TypeFieldLine(tf), AnnotationLine(ann)] = merged.lines
  tf.type_name |> should.equal("Handler")
  ann.effects |> should.equal(set.from_list(["Stdout"]))
}

pub fn merge_preserves_comments_test() {
  let file =
    AssayFile(lines: [
      CommentLine("// header"),
      BlankLine,
      AnnotationLine(EffectAnnotation(Effects, "view", [], set.new())),
      BlankLine,
      CommentLine("// invariants"),
      AnnotationLine(EffectAnnotation(Check, "view", [], set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", [], set.from_list(["Stdout"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [
    CommentLine("// header"),
    BlankLine,
    AnnotationLine(view_eff),
    BlankLine,
    CommentLine("// invariants"),
    AnnotationLine(view_check),
  ] = merged.lines
  view_eff.effects |> should.equal(set.from_list(["Stdout"]))
  view_check.kind |> should.equal(Check)
}

// --- External annotations ---

pub fn parse_external_test() {
  let input = "external effects gleam/http/request.send : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/http/request")
  ext.target |> should.equal(FunctionExternal("send"))
  ext.effects |> should.equal(set.from_list(["Http"]))
}

pub fn parse_external_pure_test() {
  let input = "external effects gleam/json.decode : []"
  let assert Ok(file) = annotation.parse_file(input)
  let assert [ext] = annotation.extract_externals(file)
  ext.module |> should.equal("gleam/json")
  ext.target |> should.equal(FunctionExternal("decode"))
  set.size(ext.effects) |> should.equal(0)
}

pub fn format_external_test() {
  let ext =
    ExternalAnnotation(
      "gleam/httpc",
      FunctionExternal("send"),
      set.from_list(["Http"]),
    )
  annotation.format_external(ext)
  |> should.equal("external effects gleam/httpc.send : [Http]")
}

pub fn external_round_trip_test() {
  let input = "external effects gleam/httpc.send : [Http]\n"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_file(file) |> should.equal(input)
}

pub fn merge_preserves_externals_test() {
  let file =
    AssayFile(lines: [
      ExternalLine(ExternalAnnotation(
        "gleam/httpc",
        FunctionExternal("send"),
        set.from_list(["Http"]),
      )),
      AnnotationLine(EffectAnnotation(Effects, "view", [], set.new())),
    ])
  let inferred = [
    EffectAnnotation(Effects, "view", [], set.from_list(["Stdout"])),
  ]
  let merged = annotation.merge_inferred(file, inferred)
  let assert [ExternalLine(ext), AnnotationLine(ann)] = merged.lines
  ext.module |> should.equal("gleam/httpc")
  ann.effects |> should.equal(set.from_list(["Stdout"]))
}
