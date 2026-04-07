import assay/internal/annotation
import assay/internal/effects
import assay/internal/types.{
  type EffectSet, AnnotationLine, AssayFile, BlankLine, Check, CommentLine,
  EffectAnnotation, Effects, ExternalAnnotation, ExternalLine, FunctionExternal,
  ModuleExternal, ParamBound, Specific, TypeFieldAnnotation, TypeFieldLine,
  Wildcard,
}
import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/set
import gleam/string
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

// ──── Generators (Cluster 3) ────

fn inferred_list_gen() -> qcheck.Generator(List(types.EffectAnnotation)) {
  let effects_ann_gen =
    qcheck.map2(function_name_gen(), effect_set_gen(), fn(function, effects) {
      EffectAnnotation(kind: Effects, function:, params: [], effects:)
    })
  qcheck.map(
    qcheck.map2(
      effects_ann_gen,
      qcheck.list_from(effects_ann_gen),
      fn(first, rest) { [first, ..rest] },
    ),
    fn(anns) {
      // Deduplicate by function name (last wins, matching dict.from_list)
      anns
      |> list.map(fn(a) { #(a.function, a) })
      |> dict.from_list()
      |> dict.values()
    },
  )
}

// ──── Cluster 3: merge_inferred Preservation ────

pub fn merge_preserves_non_effects_lines_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let non_effects = fn(f: types.AssayFile) {
    list.filter(f.lines, fn(line) {
      case line {
        AnnotationLine(a) -> a.kind != Effects
        _ -> True
      }
    })
  }
  let merged = annotation.merge_inferred(file, inferred)
  non_effects(merged) |> should.equal(non_effects(file))
}

pub fn merge_includes_all_inferred_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let merged = annotation.merge_inferred(file, inferred)
  let merged_effect_names =
    annotation.extract_annotations(merged)
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
    |> set.from_list()
  list.each(inferred, fn(a) {
    set.contains(merged_effect_names, a.function) |> should.be_true()
  })
}

pub fn merge_no_stale_effects_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let inferred_names =
    inferred |> list.map(fn(a) { a.function }) |> set.from_list()
  let merged = annotation.merge_inferred(file, inferred)
  annotation.extract_annotations(merged)
  |> list.filter(fn(a) { a.kind == Effects })
  |> list.each(fn(a) {
    set.contains(inferred_names, a.function) |> should.be_true()
  })
}

pub fn merge_effects_match_inferred_test() {
  use #(file, inferred) <- qcheck.given(
    qcheck.map2(assay_file_gen(), inferred_list_gen(), fn(f, i) { #(f, i) }),
  )
  let inferred_map =
    inferred
    |> list.map(fn(a) { #(a.function, a) })
    |> dict.from_list()
  let merged = annotation.merge_inferred(file, inferred)
  annotation.extract_annotations(merged)
  |> list.filter(fn(a) { a.kind == Effects })
  |> list.each(fn(a) {
    let assert Ok(expected) = dict.get(inferred_map, a.function)
    a |> should.equal(expected)
  })
}

// ──── Cluster 4: format_sorted Ordering Invariants ────

pub fn format_sorted_section_order_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let indices =
    parsed.lines
    |> list.filter(fn(line) { line != BlankLine })
    |> list.map(section_index)
  check_non_decreasing(indices)
}

fn section_index(line: types.AssayLine) -> Int {
  case line {
    CommentLine(_) -> 0
    ExternalLine(_) -> 1
    TypeFieldLine(_) -> 2
    AnnotationLine(a) ->
      case a.kind {
        Check -> 3
        Effects -> 4
      }
    BlankLine -> -1
  }
}

fn check_non_decreasing(xs: List(Int)) -> Nil {
  case xs {
    [] | [_] -> Nil
    [a, b, ..rest] -> {
      { a <= b } |> should.be_true()
      check_non_decreasing([b, ..rest])
    }
  }
}

pub fn format_sorted_checks_alphabetical_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let check_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Check })
    |> list.map(fn(a) { a.function })
  check_names |> should.equal(list.sort(check_names, string.compare))
}

pub fn format_sorted_effects_alphabetical_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let effects_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
  effects_names |> should.equal(list.sort(effects_names, string.compare))
}

pub fn format_sorted_trailing_newline_test() {
  use file <- qcheck.given(assay_file_gen())
  let sorted = annotation.format_sorted(file)
  string.ends_with(sorted, "\n") |> should.be_true()
}

// ──── Generators (Cluster 5) ────

fn semver_gen() -> qcheck.Generator(#(Int, Int, Int)) {
  qcheck.map2(
    qcheck.map2(qcheck.bounded_int(0, 20), qcheck.bounded_int(0, 50), fn(a, b) {
      #(a, b)
    }),
    qcheck.bounded_int(0, 100),
    fn(ab, c) { #(ab.0, ab.1, c) },
  )
}

fn semver_string_gen() -> qcheck.Generator(String) {
  qcheck.map(semver_gen(), fn(v) {
    int.to_string(v.0) <> "." <> int.to_string(v.1) <> "." <> int.to_string(v.2)
  })
}

fn version_entry_gen() -> qcheck.Generator(#(#(Int, Int, Int), String)) {
  qcheck.map(semver_gen(), fn(v) {
    let label =
      int.to_string(v.0)
      <> "."
      <> int.to_string(v.1)
      <> "."
      <> int.to_string(v.2)
    #(v, label)
  })
}

// ──── Cluster 5: Semver Ordering Laws ────

pub fn semver_lte_reflexivity_test() {
  use a <- qcheck.given(semver_gen())
  effects.semver_lte(a, a) |> should.be_true()
}

pub fn semver_lte_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
      semver_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  case effects.semver_lte(a, b) && effects.semver_lte(b, c) {
    True -> effects.semver_lte(a, c) |> should.be_true()
    False -> Nil
  }
}

pub fn semver_lte_antisymmetry_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  case effects.semver_lte(a, b) && effects.semver_lte(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn semver_lte_totality_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  let either = effects.semver_lte(a, b) || effects.semver_lte(b, a)
  either |> should.be_true()
}

pub fn compare_semver_consistent_with_lte_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(semver_gen(), semver_gen(), fn(a, b) { #(a, b) }),
  )
  let cmp = effects.compare_semver(a, b)
  let lte = effects.semver_lte(a, b)
  case cmp {
    order.Lt | order.Eq -> lte |> should.be_true()
    order.Gt -> lte |> should.be_false()
  }
}

pub fn parse_semver_roundtrip_test() {
  use s <- qcheck.given(semver_string_gen())
  let parsed = effects.parse_semver(s)
  let reparsed =
    int.to_string(parsed.0)
    <> "."
    <> int.to_string(parsed.1)
    <> "."
    <> int.to_string(parsed.2)
  reparsed |> should.equal(s)
}

pub fn pick_best_version_eligible_test() {
  use #(versions, installed) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        version_entry_gen(),
        qcheck.list_from(version_entry_gen()),
        fn(first, rest) { [first, ..rest] },
      ),
      semver_gen(),
      fn(vs, inst) { #(vs, inst) },
    ),
  )
  case effects.pick_best_version(versions, installed) {
    Ok(label) -> {
      // The picked version must exist in the input
      let assert Ok(picked) = list.find(versions, fn(v) { v.1 == label })
      // If there are eligible versions, picked must be ≤ installed
      let has_eligible =
        list.any(versions, fn(v) { effects.semver_lte(v.0, installed) })
      case has_eligible {
        True -> effects.semver_lte(picked.0, installed) |> should.be_true()
        False -> Nil
      }
    }
    Error(Nil) -> Nil
  }
}
