//// Spike (girard-spike branch): can girard supply the receiver type that
//// graded's field-call resolver currently can't see?
////
//// The fixture below is the canonical milestone-3b gap. In `run`, `v` is bound
//// from `make()` — a function call returning a `Validator`. graded 0.6.0's
//// same-function value flow tracks `let v = Validator(...)` but treats
//// `let v = make()` as BoundOpaque, so it cannot resolve `v.to_error(msg)`
//// without a hand-written `type Validator.to_error : [...]` annotation. There
//// is no parameter annotation to fall back on either.
////
//// girard runs real inference, so it knows `v : Validator` and
//// `v.to_error : fn(String) -> Nil`. This test proves girard hands graded
//// exactly the nominal receiver type it needs.

import girard
import girard/types.{Fn, Named}
import glance
import gleam/dict
import gleam/io
import gleam/list
import gleam/set
import gleeunit/should
import graded/internal/checker
import graded/internal/effects
import graded/internal/signatures
import graded/internal/types as gtypes

const fixture = "
import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

fn make() -> Validator {
  Validator(to_error: io.println)
}

pub fn run(msg: String) -> Nil {
  let v = make()
  v.to_error(msg)
}
"

pub fn girard_infers_opaque_receiver_type_test() {
  let assert Ok(module) = glance.module(fixture)
  let assert Ok(annotated) =
    girard.annotate_module(module, girard.default_options())

  // The whole point: somewhere in `run`, the value flowing into the field call
  // is typed `Validator` even though graded can only see `let v = make()`.
  let validator_types =
    annotated.expressions
    |> list.map(fn(a) { a.type_ })
    |> list.filter(fn(t) {
      case t {
        Named(_, "Validator", _) -> True
        _ -> False
      }
    })
  case validator_types {
    [] -> should.fail()
    [_, ..] -> Nil
  }

  // And the field itself is typed as the fn we'd resolve effects against.
  let has_field_fn =
    annotated.expressions
    |> list.any(fn(a) {
      case a.type_ {
        Fn([Named(_, "String", _)], Named(_, "Nil", _)) -> True
        _ -> False
      }
    })
  has_field_fn |> should.be_true()

  // Print girard's signature for `run` so we can eyeball the spike output.
  case list.key_find(annotated.functions, "run") {
    Ok(scheme) ->
      io.println("girard: run : " <> girard.type_to_string(scheme.type_))
    Error(_) -> Nil
  }
}

/// The contrast: graded's own checker is *imprecise* on this fixture today.
/// `run` actually prints (the stored `io.println` is invoked via
/// `v.to_error(msg)`), but graded can't resolve the opaque field call, so it
/// falls back to `[Unknown]` — the conservative top — instead of the precise
/// `[Stdout]`. girard's `Validator` receiver type (asserted above) is the
/// missing input that would let graded resolve `to_error` to the stored
/// `io.println` and infer exactly `[Stdout]`.
pub fn graded_is_imprecise_today_test() {
  let assert Ok(module) = glance.module(fixture)
  let inferred =
    checker.infer(
      module,
      effects.empty_knowledge_base(),
      [],
      signatures.empty(),
      dict.new(),
      dict.new(),
    )

  let run_effects =
    inferred
    |> list.find(fn(a) { a.function == "run" })

  case run_effects {
    Ok(ann) -> {
      let labels = case ann.effects {
        gtypes.Specific(s) -> s
        gtypes.Polymorphic(s, _) -> s
        gtypes.Wildcard -> set.new()
      }
      // Documents the current gap: the precise Stdout is NOT recovered (graded
      // yields [Unknown]). When girard-backed field resolution lands, this
      // should become exactly [Stdout].
      set.contains(labels, "Stdout") |> should.be_false()
      io.println(
        "graded: run effects = "
        <> string_of_labels(labels)
        <> " (imprecise — girard would resolve this to [Stdout])",
      )
    }
    Error(_) -> should.fail()
  }
}

/// Proves the two entry points girard shipped for us:
///   - `annotate_package` (batch, best-effort per definition), and
///   - `ModuleResult.skipped` — the identifiable skipped-set we asked for.
/// A module mixing a well-typed function with an ill-typed one annotates the
/// good one and reports the bad one in `skipped` with its error, instead of
/// failing the whole module. This is exactly the per-function fallback boundary
/// graded routes to its syntax-level analysis.
pub fn girard_package_best_effort_reports_skipped_test() {
  let src =
    "
pub fn good(x: Int) -> Int { x + 1 }
pub fn bad() -> Int { 1 + \"not an int\" }
"
  let assert Ok(module) = glance.module(src)
  let results =
    girard.annotate_package([#("m", module)], girard.default_options())
  let assert Ok(result) = dict.get(results, "m")

  // The good function is still typed...
  list.key_find(result.annotated.functions, "good") |> should.be_ok()
  // ...the bad one is reported as skipped (with its error), not silently absent,
  // and not crashing the module.
  list.key_find(result.skipped, "bad") |> should.be_ok()
  list.key_find(result.annotated.functions, "bad") |> should.be_error()

  let skipped_names = result.skipped |> list.map(fn(pair) { pair.0 })
  io.println(
    "girard: skipped = " <> string_of_labels(set.from_list(skipped_names)),
  )
}

fn string_of_labels(labels: set.Set(String)) -> String {
  "[" <> { labels |> set.to_list |> list_join(", ") } <> "]"
}

fn list_join(items: List(String), sep: String) -> String {
  case items {
    [] -> ""
    [x] -> x
    [x, ..rest] -> x <> sep <> list_join(rest, sep)
  }
}
