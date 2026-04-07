import assay/internal/annotation
import assay/internal/types.{
  AnnotationLine, BlankLine, Check, CommentLine, Effects, ExternalLine,
  TypeFieldLine,
}
import generators
import gleam/list
import gleam/string
import gleeunit/should
import qcheck

pub fn preserves_comments_test() {
  let input =
    "// file header
// another comment
effects view : []
check view : []"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "// file header
// another comment

check view : []

effects view : []
",
  )
}

pub fn only_check_lines_test() {
  let input = "check view : []\ncheck update : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "check update : [Http]
check view : []
",
  )
}

pub fn only_effects_lines_test() {
  let input = "effects view : []\neffects update : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "effects update : [Http]
effects view : []
",
  )
}

pub fn empty_file_test() {
  let input = ""
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal("\n")
}

pub fn normalizes_spacing_test() {
  let input = "effects   view  :  [ Http ,  Dom ]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal("effects view : [Dom, Http]\n")
}

pub fn sorts_effect_labels_test() {
  let input = "effects handler : [Stdout, Http, Db]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal("effects handler : [Db, Http, Stdout]\n")
}

// ──── format_sorted Ordering Invariants (property) ────

pub fn format_sorted_section_order_test() {
  use file <- qcheck.given(generators.assay_file_gen())
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
  use file <- qcheck.given(generators.assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let check_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Check })
    |> list.map(fn(a) { a.function })
  check_names |> should.equal(list.sort(check_names, string.compare))
}

pub fn format_sorted_effects_alphabetical_test() {
  use file <- qcheck.given(generators.assay_file_gen())
  let sorted = annotation.format_sorted(file)
  let assert Ok(parsed) = annotation.parse_file(sorted)
  let effects_names =
    annotation.extract_annotations(parsed)
    |> list.filter(fn(a) { a.kind == Effects })
    |> list.map(fn(a) { a.function })
  effects_names |> should.equal(list.sort(effects_names, string.compare))
}

pub fn format_sorted_trailing_newline_test() {
  use file <- qcheck.given(generators.assay_file_gen())
  let sorted = annotation.format_sorted(file)
  string.ends_with(sorted, "\n") |> should.be_true()
}
