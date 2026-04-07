import assay/internal/effects
import assay/internal/types.{QualifiedName}
import gleam/set
import gleeunit/should

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

pub fn known_effectful_test() {
  effects.lookup_effects(knowledge_base(), QualifiedName("gleam/io", "println"))
  |> should.equal(set.from_list(["Stdout"]))
}

pub fn known_pure_module_test() {
  effects.lookup_effects(knowledge_base(), QualifiedName("gleam/list", "map"))
  |> should.equal(set.new())
}

pub fn unknown_function_test() {
  effects.lookup_effects(
    knowledge_base(),
    QualifiedName("some/unknown", "thing"),
  )
  |> should.equal(set.from_list(["Unknown"]))
}

pub fn lookup_known_variant_test() {
  effects.lookup(knowledge_base(), QualifiedName("gleam/io", "debug"))
  |> should.equal(effects.Known(set.from_list(["Stdout"])))
}

pub fn lookup_unknown_variant_test() {
  effects.lookup(knowledge_base(), QualifiedName("mystery/module", "foo"))
  |> should.equal(effects.Unknown)
}

pub fn format_effect_set_empty_test() {
  effects.format_effect_set(set.new())
  |> should.equal("[]")
}

pub fn format_effect_set_sorted_test() {
  effects.format_effect_set(set.from_list(["Http", "Dom"]))
  |> should.equal("[Dom, Http]")
}
