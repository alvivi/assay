import glance
import gleam/dict
import gleam/list
import gleeunit/should
import graded/internal/extract

pub fn module_path_simple_test() {
  extract.module_path_for_source("src/app.gleam", "src")
  |> should.equal("app")
}

pub fn module_path_nested_test() {
  extract.module_path_for_source("src/app/router.gleam", "src")
  |> should.equal("app/router")
}

pub fn module_path_custom_directory_test() {
  extract.module_path_for_source("test/fixtures/view.gleam", "test/fixtures")
  |> should.equal("view")
}

pub fn module_path_deeply_nested_test() {
  extract.module_path_for_source("src/app/web/handlers/auth.gleam", "src")
  |> should.equal("app/web/handlers/auth")
}

/// Critical: the dotted module name we compute for a `.gleam` file must
/// exactly match the string `extract.build_import_context` produces when
/// another module imports it. The topological sort relies on intersecting
/// these two views — if they ever drift, dependency edges silently
/// disappear and inference degenerates back to the per-file behaviour.
pub fn module_path_matches_import_context_test() {
  // Compute the module name for a fake "leaf" file as it would live on disk.
  let leaf_module = extract.module_path_for_source("src/app/d.gleam", "src")

  // Parse a sibling that imports it and read what extract sees.
  let src =
    "import app/d
pub fn run() { d.format(\"hi\") }"
  let assert Ok(module) = glance.module(src)
  let ctx = extract.build_import_context(module)

  // The extracted import path must match what we computed from the file path.
  ctx.aliases
  |> dict.values()
  |> list.contains(leaf_module)
  |> should.be_true()
}

pub fn module_path_matches_import_context_nested_test() {
  let leaf_module =
    extract.module_path_for_source("src/app/web/handlers/auth.gleam", "src")

  let src =
    "import app/web/handlers/auth
pub fn run() { auth.check() }"
  let assert Ok(module) = glance.module(src)
  let ctx = extract.build_import_context(module)

  ctx.aliases
  |> dict.values()
  |> list.contains(leaf_module)
  |> should.be_true()
}
