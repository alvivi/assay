import assay/internal/annotation
import assay/internal/types.{
  type EffectSet, AnnotationLine, AssayFile, BlankLine, Check, CommentLine,
  EffectAnnotation, Effects, ExternalAnnotation, ExternalLine, FunctionExternal,
  ModuleExternal, ParamBound, Specific, TypeFieldAnnotation, TypeFieldLine,
  Wildcard,
}
import gleam/set
import gleeunit/should
import qcheck

// ──── Generators ────

fn effect_set_gen() -> qcheck.Generator(EffectSet) {
  let label_gen =
    qcheck.from_generators(qcheck.return("Http"), [
      qcheck.return("Dom"),
      qcheck.return("Stdout"),
      qcheck.return("Db"),
      qcheck.return("FileSystem"),
      qcheck.return("Time"),
    ])
  let specific_gen =
    qcheck.map(qcheck.list_from(label_gen), fn(labels) {
      Specific(set.from_list(labels))
    })
  qcheck.from_weighted_generators(#(1, qcheck.return(Wildcard)), [
    #(4, specific_gen),
  ])
}

fn function_name_gen() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("foo"), [
    qcheck.return("bar"),
    qcheck.return("baz"),
    qcheck.return("run"),
    qcheck.return("handle"),
    qcheck.return("process"),
  ])
}

fn kind_gen() -> qcheck.Generator(types.AnnotationKind) {
  qcheck.from_generators(qcheck.return(Effects), [qcheck.return(Check)])
}

fn param_bound_gen() -> qcheck.Generator(types.ParamBound) {
  let param_name_gen =
    qcheck.from_generators(qcheck.return("f"), [
      qcheck.return("g"),
      qcheck.return("h"),
      qcheck.return("callback"),
      qcheck.return("handler"),
    ])
  qcheck.map2(param_name_gen, effect_set_gen(), fn(name, effects) {
    ParamBound(name:, effects:)
  })
}

fn annotation_gen() -> qcheck.Generator(types.EffectAnnotation) {
  let no_params =
    qcheck.map2(
      qcheck.map2(kind_gen(), function_name_gen(), fn(k, f) { #(k, f) }),
      effect_set_gen(),
      fn(kf, effects) {
        let #(kind, function) = kf
        EffectAnnotation(kind:, function:, params: [], effects:)
      },
    )
  let with_param =
    qcheck.map2(
      qcheck.map2(kind_gen(), function_name_gen(), fn(k, f) { #(k, f) }),
      qcheck.map2(param_bound_gen(), effect_set_gen(), fn(p, e) { #(p, e) }),
      fn(kf, pe) {
        let #(kind, function) = kf
        let #(param, effects) = pe
        EffectAnnotation(kind:, function:, params: [param], effects:)
      },
    )
  qcheck.from_generators(no_params, [with_param])
}

fn type_field_gen() -> qcheck.Generator(types.TypeFieldAnnotation) {
  let type_name_gen =
    qcheck.from_generators(qcheck.return("Handler"), [
      qcheck.return("Request"),
      qcheck.return("Config"),
    ])
  let field_name_gen =
    qcheck.from_generators(qcheck.return("on_click"), [
      qcheck.return("send"),
      qcheck.return("validate"),
    ])
  qcheck.map2(
    qcheck.map2(type_name_gen, field_name_gen, fn(t, f) { #(t, f) }),
    effect_set_gen(),
    fn(tf, effects) {
      let #(type_name, field) = tf
      TypeFieldAnnotation(type_name:, field:, effects:)
    },
  )
}

fn external_gen() -> qcheck.Generator(types.ExternalAnnotation) {
  let module_name_gen =
    qcheck.from_generators(qcheck.return("gleam/io"), [
      qcheck.return("gleam/list"),
      qcheck.return("gleam/httpc"),
      qcheck.return("simplifile"),
    ])
  let module_ext =
    qcheck.map2(module_name_gen, effect_set_gen(), fn(module, effects) {
      ExternalAnnotation(module:, target: ModuleExternal, effects:)
    })
  let function_ext =
    qcheck.map2(
      qcheck.map2(module_name_gen, function_name_gen(), fn(m, f) { #(m, f) }),
      effect_set_gen(),
      fn(mf, effects) {
        let #(module, name) = mf
        ExternalAnnotation(module:, target: FunctionExternal(name), effects:)
      },
    )
  qcheck.from_generators(module_ext, [function_ext])
}

fn assay_line_gen() -> qcheck.Generator(types.AssayLine) {
  let comment_gen =
    qcheck.from_generators(qcheck.return("// TODO"), [
      qcheck.return("// Effect annotations"),
      qcheck.return("// Auto-generated"),
    ])
  qcheck.from_weighted_generators(
    #(3, qcheck.map(annotation_gen(), AnnotationLine)),
    [
      #(1, qcheck.map(type_field_gen(), TypeFieldLine)),
      #(1, qcheck.map(external_gen(), ExternalLine)),
      #(1, qcheck.map(comment_gen, CommentLine)),
      #(1, qcheck.return(BlankLine)),
    ],
  )
}

fn assay_file_gen() -> qcheck.Generator(types.AssayFile) {
  qcheck.map2(
    assay_line_gen(),
    qcheck.list_from(assay_line_gen()),
    fn(first, rest) { AssayFile(lines: [first, ..rest]) },
  )
}

// ──── Cluster 1: EffectSet Lattice Laws ────

pub fn subset_reflexivity_test() {
  use a <- qcheck.given(effect_set_gen())
  types.is_subset(a, a) |> should.be_true()
}

pub fn subset_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
      effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  case types.is_subset(a, b) && types.is_subset(b, c) {
    True -> types.is_subset(a, c) |> should.be_true()
    False -> Nil
  }
}

pub fn subset_antisymmetry_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  case types.is_subset(a, b) && types.is_subset(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn union_commutativity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  types.union(a, b) |> should.equal(types.union(b, a))
}

pub fn union_associativity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
      effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  types.union(types.union(a, b), c)
  |> should.equal(types.union(a, types.union(b, c)))
}

pub fn union_idempotence_test() {
  use a <- qcheck.given(effect_set_gen())
  types.union(a, a) |> should.equal(a)
}

pub fn union_identity_test() {
  use a <- qcheck.given(effect_set_gen())
  types.union(a, types.empty()) |> should.equal(a)
}

pub fn wildcard_absorbs_union_test() {
  use a <- qcheck.given(effect_set_gen())
  types.union(Wildcard, a) |> should.equal(Wildcard)
}

pub fn empty_is_bottom_test() {
  use a <- qcheck.given(effect_set_gen())
  types.is_subset(types.empty(), a) |> should.be_true()
}

pub fn wildcard_is_top_test() {
  use a <- qcheck.given(effect_set_gen())
  types.is_subset(a, Wildcard) |> should.be_true()
}

pub fn union_monotonicity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  types.is_subset(a, types.union(a, b)) |> should.be_true()
}

pub fn subset_union_compatibility_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(effect_set_gen(), effect_set_gen(), fn(a, b) { #(a, b) }),
  )
  let subset = types.is_subset(a, b)
  let union_eq = types.union(a, b) == b
  subset |> should.equal(union_eq)
}

// ──── Cluster 2: Parse/Format Roundtrips ────

pub fn annotation_roundtrip_test() {
  use a <- qcheck.given(annotation_gen())
  let formatted = annotation.format_annotation(a)
  let assert Ok(parsed) = annotation.parse(formatted)
  parsed |> should.equal([a])
}

pub fn type_field_roundtrip_test() {
  use tf <- qcheck.given(type_field_gen())
  let formatted = annotation.format_type_field(tf)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [TypeFieldLine(parsed)] = file.lines
  parsed |> should.equal(tf)
}

pub fn external_roundtrip_test() {
  use ext <- qcheck.given(external_gen())
  let formatted = annotation.format_external(ext)
  let assert Ok(file) = annotation.parse_file(formatted)
  let assert [ExternalLine(parsed)] = file.lines
  parsed |> should.equal(ext)
}

pub fn file_roundtrip_test() {
  use file <- qcheck.given(assay_file_gen())
  let formatted = annotation.format_file(file)
  let assert Ok(parsed) = annotation.parse_file(formatted)
  parsed |> should.equal(file)
}

pub fn format_sorted_idempotence_test() {
  use file <- qcheck.given(assay_file_gen())
  let s1 = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(s1)
  let s2 = annotation.format_sorted(parsed)
  s1 |> should.equal(s2)
}
