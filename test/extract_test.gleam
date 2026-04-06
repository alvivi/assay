import assay/extract
import assay/types.{QualifiedName}
import glance
import gleam/list
import gleeunit/should

fn parse_and_extract(src: String) -> extract.ExtractResult {
  let assert Ok(module) = glance.module(src)
  let ctx = extract.build_import_context(module)
  let assert Ok(func) =
    list.find(module.functions, fn(def) { def.definition.name == "target" })
  extract.extract_calls(func.definition.body, ctx)
}

pub fn qualified_call_test() {
  let src =
    "import gleam/io
pub fn target() { io.println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
  result.local |> should.equal([])
}

pub fn unqualified_call_test() {
  let src =
    "import gleam/io.{println}
pub fn target() { println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn local_call_test() {
  let src =
    "pub fn target() { helper() }
fn helper() { Nil }"
  let result = parse_and_extract(src)
  result.resolved |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["helper"])
}

pub fn pipe_qualified_test() {
  let src =
    "import gleam/io
pub fn target() { \"hi\" |> io.println }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn pipe_unqualified_test() {
  let src =
    "import gleam/io.{println}
pub fn target() { \"hi\" |> println }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn closure_test() {
  let src =
    "import gleam/io
pub fn target() { fn() { io.println(\"x\") } }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn case_branches_test() {
  let src =
    "import gleam/io
pub fn target(x) {
  case x {
    True -> io.println(\"yes\")
    False -> io.println(\"no\")
  }
}"
  let result = parse_and_extract(src)
  result.resolved |> list.length() |> should.equal(2)
}

pub fn multiple_calls_test() {
  let src =
    "import gleam/io
import gleam/list
pub fn target(items) {
  list.map(items, io.println)
}"
  let result = parse_and_extract(src)
  // list.map is a resolved call, io.println appears as argument (FieldAccess)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> list.contains(QualifiedName("gleam/list", "map"))
  |> should.be_true()
}

pub fn nested_closure_test() {
  let src =
    "import gleam/io
pub fn target() { fn() { fn() { io.println(\"deep\") } } }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn case_guard_test() {
  let src =
    "import gleam/io
pub fn target(x) {
  case x {
    n if n > 0 -> io.println(\"pos\")
    _ -> Nil
  }
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn assignment_expression_test() {
  let src =
    "import gleam/io
pub fn target() {
  let x = io.println(\"hi\")
  x
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn pipe_chain_test() {
  let src =
    "import gleam/string
import gleam/io
pub fn target(x) {
  x |> string.uppercase |> io.println
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> list.contains(QualifiedName("gleam/io", "println"))
  |> should.be_true()
  result.resolved
  |> list.map(fn(r) { r.name })
  |> list.contains(QualifiedName("gleam/string", "uppercase"))
  |> should.be_true()
}

pub fn block_expression_test() {
  let src =
    "import gleam/io
pub fn target() {
  {
    io.println(\"in block\")
  }
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn aliased_import_test() {
  let src =
    "import gleam/io as output
pub fn target() { output.println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

// Field call tests

pub fn field_access_call_test() {
  let src = "pub fn target(handler) { handler.on_click(event) }"
  let result = parse_and_extract(src)
  result.field |> list.length() |> should.equal(1)
  let assert [fc] = result.field
  fc.object |> should.equal("handler")
  fc.label |> should.equal("on_click")
  result.local |> should.equal([])
}

pub fn field_access_pipe_test() {
  let src = "pub fn target(handler) { event |> handler.on_click }"
  let result = parse_and_extract(src)
  result.field |> list.length() |> should.equal(1)
  let assert [fc] = result.field
  fc.object |> should.equal("handler")
  fc.label |> should.equal("on_click")
}

pub fn import_not_confused_with_field_test() {
  let src =
    "import gleam/io
pub fn target() { io.println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved |> list.length() |> should.equal(1)
  result.field |> should.equal([])
}
