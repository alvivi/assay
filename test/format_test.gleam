import assay/internal/annotation
import gleeunit/should

pub fn sorts_check_before_effects_test() {
  let input =
    "effects update : [Http]
check view : []
effects view : []
check update : [Http]"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "check update : [Http]
check view : []

effects update : [Http]
effects view : []
",
  )
}

pub fn alphabetical_within_groups_test() {
  let input =
    "effects zebra : []
effects alpha : [Stdout]
check zebra : []
check alpha : []"
  let assert Ok(file) = annotation.parse_file(input)
  annotation.format_sorted(file)
  |> should.equal(
    "check alpha : []
check zebra : []

effects alpha : [Stdout]
effects zebra : []
",
  )
}

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
  // Parser already normalizes spacing, so parse + format_sorted cleans up
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
