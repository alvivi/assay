import glance
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import graded/internal/signatures
import graded/internal/types.{QualifiedName}
import simplifile

// ──── Glance AST detection ────

pub fn glance_detects_fn_typed_param_test() {
  let source =
    "
pub fn apply(f: fn(Int) -> Int, x: Int) -> Int {
  f(x)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.from_list(["f"]))
}

pub fn glance_skips_non_fn_params_test() {
  let source =
    "
pub fn greet(name: String) -> String {
  name
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.new())
}

pub fn glance_skips_unannotated_params_test() {
  let source =
    "
pub fn apply(f, x) {
  f(x)
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.new())
}

pub fn glance_detects_multiple_fn_typed_params_test() {
  let source =
    "
pub fn apply2(f: fn(Int) -> Int, g: fn(Int) -> Int, x: Int) -> Int {
  g(f(x))
}
"
  let assert Ok(module) = glance.module(source)
  let assert [definition] = module.functions
  signatures.fn_typed_params_from_function(definition.definition)
  |> should.equal(set.from_list(["f", "g"]))
}

// ──── Loading from a packages directory ────

pub fn load_from_packages_dir_walks_dep_sources_test() {
  let dir = "/tmp/graded_signatures_test_pkgs"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) =
    simplifile.create_directory_all(dir <> "/fake_dep/src/fake")
  let assert Ok(Nil) =
    simplifile.write(
      dir <> "/fake_dep/src/fake/list.gleam",
      "pub fn map(items: List(a), f: fn(a) -> b) -> List(b) {
  todo
}
",
    )

  let registry = signatures.load_from_packages_dir(dir)
  let params = signatures.lookup(registry, QualifiedName("fake/list", "map"))
  let assert Some([_items, f_param]) = params
  f_param.is_fn_typed |> should.be_true()
  f_param.position |> should.equal(1)

  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_from_packages_dir_skips_missing_src_test() {
  let dir = "/tmp/graded_signatures_test_skip"
  let _ = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir <> "/erlang_only")

  let registry = signatures.load_from_packages_dir(dir)
  signatures.lookup(registry, QualifiedName("anything", "foo"))
  |> should.equal(None)

  let _ = simplifile.delete(dir)
  Nil
}
