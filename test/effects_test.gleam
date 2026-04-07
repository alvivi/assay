import assay/internal/effects
import assay/internal/types.{QualifiedName, Specific, Wildcard}
import generators
import gleam/int
import gleam/list
import gleam/order
import gleam/set
import gleeunit/should
import qcheck

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

pub fn known_effectful_test() {
  effects.lookup_effects(knowledge_base(), QualifiedName("gleam/io", "println"))
  |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn known_pure_module_test() {
  effects.lookup_effects(knowledge_base(), QualifiedName("gleam/list", "map"))
  |> should.equal(Specific(set.new()))
}

pub fn unknown_function_test() {
  effects.lookup_effects(
    knowledge_base(),
    QualifiedName("some/unknown", "thing"),
  )
  |> should.equal(Specific(set.from_list(["Unknown"])))
}

pub fn lookup_known_variant_test() {
  effects.lookup(knowledge_base(), QualifiedName("gleam/io", "debug"))
  |> should.equal(effects.Known(Specific(set.from_list(["Stdout"]))))
}

pub fn lookup_unknown_variant_test() {
  effects.lookup(knowledge_base(), QualifiedName("mystery/module", "foo"))
  |> should.equal(effects.Unknown)
}

pub fn format_effect_set_empty_test() {
  effects.format_effect_set(Specific(set.new()))
  |> should.equal("[]")
}

pub fn format_effect_set_sorted_test() {
  effects.format_effect_set(Specific(set.from_list(["Http", "Dom"])))
  |> should.equal("[Dom, Http]")
}

pub fn format_wildcard_set_test() {
  effects.format_effect_set(Wildcard) |> should.equal("[_]")
}

// ──── EffectSet Lattice Laws ────

pub fn subset_reflexivity_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(a, a) |> should.be_true()
}

pub fn subset_transitivity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        generators.effect_set_gen(),
        generators.effect_set_gen(),
        fn(a, b) { #(a, b) },
      ),
      generators.effect_set_gen(),
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
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  case types.is_subset(a, b) && types.is_subset(b, a) {
    True -> a |> should.equal(b)
    False -> Nil
  }
}

pub fn union_commutativity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  types.union(a, b) |> should.equal(types.union(b, a))
}

pub fn union_associativity_test() {
  use #(a, b, c) <- qcheck.given(
    qcheck.map2(
      qcheck.map2(
        generators.effect_set_gen(),
        generators.effect_set_gen(),
        fn(a, b) { #(a, b) },
      ),
      generators.effect_set_gen(),
      fn(ab, c) { #(ab.0, ab.1, c) },
    ),
  )
  types.union(types.union(a, b), c)
  |> should.equal(types.union(a, types.union(b, c)))
}

pub fn union_idempotence_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(a, a) |> should.equal(a)
}

pub fn union_identity_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(a, types.empty()) |> should.equal(a)
}

pub fn wildcard_absorbs_union_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.union(Wildcard, a) |> should.equal(Wildcard)
}

pub fn empty_is_bottom_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(types.empty(), a) |> should.be_true()
}

pub fn wildcard_is_top_test() {
  use a <- qcheck.given(generators.effect_set_gen())
  types.is_subset(a, Wildcard) |> should.be_true()
}

pub fn union_monotonicity_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  types.is_subset(a, types.union(a, b)) |> should.be_true()
}

pub fn subset_union_compatibility_test() {
  use #(a, b) <- qcheck.given(
    qcheck.map2(
      generators.effect_set_gen(),
      generators.effect_set_gen(),
      fn(a, b) { #(a, b) },
    ),
  )
  let subset = types.is_subset(a, b)
  let union_eq = types.union(a, b) == b
  subset |> should.equal(union_eq)
}

// ──── Semver Ordering Laws ────

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
      let assert Ok(picked) = list.find(versions, fn(v) { v.1 == label })
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
