import gleam/list
import gleam/set
import gleeunit/should
import graded
import graded/internal/annotation
import graded/internal/types
import simplifile

pub fn pure_view_passes_test() {
  let assert Ok(results) = graded.run("test/fixtures")
  let pure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/pure_view.gleam" })
  let assert Ok(r) = pure_result
  r.violations |> should.equal([])
}

pub fn impure_view_fails_test() {
  let assert Ok(results) = graded.run("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("view")
  v.call.function |> should.equal("println")
}

pub fn transitive_violation_detected_test() {
  let assert Ok(results) = graded.run("test/fixtures")
  let trans_result =
    list.find(results, fn(r) { r.file == "test/fixtures/transitive.gleam" })
  let assert Ok(r) = trans_result
  { r.violations != [] } |> should.be_true()
}

pub fn validator_flow_violation_detected_test() {
  // validator_flow.run constructs a Validator locally and calls its
  // field. The field is wired to io.println so the run function's
  // effects are [Stdout] — the check budget of [] must fail.
  let assert Ok(results) = graded.run("test/fixtures")
  let validator_result =
    list.find(results, fn(r) { r.file == "test/fixtures/validator_flow.gleam" })
  let assert Ok(r) = validator_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.call.function |> should.equal("println")
}

pub fn opaque_receiver_violation_detected_test() {
  // opaque_receiver.run binds its Validator from make() — a *cross-function*
  // construction the syntax-level path can't see. girard types the receiver,
  // and the `type opaque_receiver.Validator.to_error : [Stdout]` annotation
  // resolves the field call, so the [] check budget must fail. This is the
  // milestone-3b case that 0.6.0's same-function value flow could not handle.
  let assert Ok(results) = graded.run("test/fixtures")
  let opaque_result =
    list.find(results, fn(r) { r.file == "test/fixtures/opaque_receiver.gleam" })
  let assert Ok(r) = opaque_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  // Crucially the effect is the precise [Stdout] (resolved via the type
  // annotation), not the [Unknown] graded would fall back to without girard.
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn inferred_field_effect_from_construction_test() {
  // Stage C: inferred_field has NO `type Logger.emit` annotation. graded
  // derives the field's effect from the construction `Logger(emit: io.println)`
  // and girard types the receiver, so the [] check budget fails with the
  // precise [Stdout] — no hand-written type annotation needed.
  let assert Ok(results) = graded.run("test/fixtures")
  let inferred_result =
    list.find(results, fn(r) { r.file == "test/fixtures/inferred_field.gleam" })
  let assert Ok(r) = inferred_result
  { r.violations != [] } |> should.be_true()
  let assert [v, ..] = r.violations
  v.function |> should.equal("run")
  v.actual |> should.equal(types.Specific(set.from_list(["Stdout"])))
}

pub fn infer_then_check_round_trip_test() {
  // `run_infer` rewrites the spec file in place, so capture the canonical
  // fixture content up front and restore it at the end — keeping the test
  // self-contained rather than duplicating the fixture as a literal here.
  let spec_path = "test/fixtures/fixtures.graded"
  let assert Ok(original) = simplifile.read(spec_path)

  // Infer regenerates the public-effects portion of the spec file while
  // preserving the hand-written check lines.
  let assert Ok(Nil) = graded.run_infer("test/fixtures")

  let assert Ok(content) = simplifile.read(spec_path)
  let assert Ok(file) = annotation.parse_file(content)

  // The spec file's check lines should still be there after `infer`.
  let checks = annotation.extract_checks(file)
  { list.length(checks) >= 3 } |> should.be_true()

  // Inferred effects lines should also be present.
  let all = annotation.extract_annotations(file)
  { list.length(all) > list.length(checks) } |> should.be_true()

  // Check still catches violations via the spec's check annotations.
  let assert Ok(results) = graded.run("test/fixtures")
  let impure_result =
    list.find(results, fn(r) { r.file == "test/fixtures/impure_view.gleam" })
  let assert Ok(r) = impure_result
  { r.violations != [] } |> should.be_true()

  // Restore the captured fixture so subsequent test runs start clean.
  let assert Ok(Nil) = simplifile.write(spec_path, original)
}
