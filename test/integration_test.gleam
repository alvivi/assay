import assay
import assay/internal/annotation
import gleam/list
import gleeunit/should
import simplifile

pub fn pure_view_passes_test() {
  let assert Ok(results) = assay.run("test/fixtures")
  let pure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/pure_view.gleam" })
  let assert Ok(r) = pure_result
  r.violations |> should.equal([])
}

pub fn impure_view_fails_test() {
  let assert Ok(results) = assay.run("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("view")
  v.call.function |> should.equal("println")
}

pub fn transitive_violation_detected_test() {
  let assert Ok(results) = assay.run("test/fixtures")
  let trans_result =
    list.find(results, fn(r) { r.file == "test/fixtures/transitive.gleam" })
  let assert Ok(r) = trans_result
  { r.violations != [] } |> should.be_true()
}

pub fn infer_then_check_round_trip_test() {
  // Infer writes effects lines, check still enforces check lines
  let assert Ok(Nil) = assay.run_infer("test/fixtures")

  // Verify the inferred file was written and preserves check lines
  let assert Ok(content) =
    simplifile.read("test/fixtures/priv/assay/impure_view.assay")
  let assert Ok(file) = annotation.parse_file(content)

  // check line should still be there
  let checks = annotation.extract_checks(file)
  { checks != [] } |> should.be_true()

  // effects line should have been added
  let all = annotation.extract_annotations(file)
  { list.length(all) > list.length(checks) } |> should.be_true()

  // Check still catches violations via check lines
  let assert Ok(results) = assay.run("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()

  // Restore fixture files
  let assert Ok(Nil) =
    simplifile.write(
      "test/fixtures/priv/assay/pure_view.assay",
      "check view : []\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      "test/fixtures/priv/assay/impure_view.assay",
      "check view : []\n",
    )
  let assert Ok(Nil) =
    simplifile.write(
      "test/fixtures/priv/assay/transitive.assay",
      "check view : []\n",
    )
}
