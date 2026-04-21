import glance
import gleam/dict
import gleam/list
import gleeunit/should
import graded/internal/extract
import graded/internal/types.{FunctionRef, QualifiedName}

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
  // list.map is a resolved call, io.println is a function reference
  result.resolved
  |> list.map(fn(r) { r.name })
  |> list.contains(QualifiedName("gleam/list", "map"))
  |> should.be_true()
  result.references
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn unqualified_function_ref_test() {
  let src =
    "import gleam/io.{println}
import gleam/list
pub fn target(items) { list.map(items, println) }"
  let result = parse_and_extract(src)
  result.references
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
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

// Constructor tests

pub fn constructors_not_tracked_as_calls_test() {
  let src =
    "import gleam/string
pub fn target(value) {
  let trimmed = string.trim(value)
  case trimmed {
    \"\" -> Error(Nil)
    _ -> Ok(trimmed)
  }
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/string", "trim")])
  result.local |> should.equal([])
}

pub fn custom_constructor_not_tracked_test() {
  let src =
    "pub type Id { Id(value: String) }
pub fn target(x) { Id(x) }"
  let result = parse_and_extract(src)
  result.resolved |> should.equal([])
  result.local |> should.equal([])
}

pub fn pipe_to_constructor_not_tracked_test() {
  let src = "pub fn target(x) { x |> Ok }"
  let result = parse_and_extract(src)
  result.resolved |> should.equal([])
  result.local |> should.equal([])
}

pub fn import_not_confused_with_field_test() {
  let src =
    "import gleam/io
pub fn target() { io.println(\"hi\") }"
  let result = parse_and_extract(src)
  result.resolved |> list.length() |> should.equal(1)
  result.field |> should.equal([])
}

// ──── Local binding resolution (same-function value flow) ────

pub fn function_ref_alias_call_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
  result.local |> should.equal([])
}

pub fn unqualified_ref_alias_call_test() {
  let src =
    "import gleam/io.{println}
pub fn target() {
  let f = println
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn transitive_alias_call_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  let g = f
  g(\"hi\")
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn pipe_to_local_binding_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  \"hi\" |> f
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn shadowing_overwrites_test() {
  let src =
    "import gleam/io
pub fn target() {
  let f = io.println
  let f = some_opaque_thing
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  // Second `let f = <opaque>` overwrites; call resolves as local.
  result.resolved |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["f"])
}

pub fn block_scope_does_not_leak_test() {
  let src =
    "import gleam/io
pub fn target() {
  {
    let f = io.println
    Nil
  }
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  // `f` inside the block doesn't leak; outer `f(\"hi\")` is a local call.
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["f"])
}

pub fn pattern_destructure_is_opaque_test() {
  let src =
    "import gleam/io
pub fn target() {
  let #(f, _) = #(io.println, 1)
  f(\"hi\")
}"
  let result = parse_and_extract(src)
  // Destructuring drops tracking — `f` is opaque, call stays local.
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([])
  result.local
  |> list.map(fn(l) { l.function })
  |> should.equal(["f"])
}

pub fn constructor_field_call_resolves_test() {
  let src =
    "import gleam/io
pub type Validator { Validator(to_error: fn(Int) -> Nil) }
pub fn target() {
  let v = Validator(to_error: io.println)
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
  result.field |> should.equal([])
}

pub fn constructor_field_call_unresolved_falls_back_test() {
  let src =
    "pub type Validator { Validator(to_error: fn(Int) -> Nil) }
pub fn target() {
  let v = Validator(to_error: some_closure())
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  // The to_error value is a call result — OtherExpression — so we
  // fall back to a FieldCall so type-level annotations can still apply.
  result.field
  |> list.map(fn(f) { #(f.object, f.label) })
  |> should.equal([#("v", "to_error")])
}

pub fn constructor_positional_arg_matches_label_test() {
  let src =
    "import gleam/io
pub type Validator { Validator(to_error: fn(Int) -> Nil) }
pub fn target() {
  let v = Validator(io.println)
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn constructor_mixed_positional_and_labelled_test() {
  let src =
    "import gleam/io
pub type Handler {
  Handler(on_click: fn() -> Nil, on_hover: fn() -> Nil)
}
pub fn target() {
  let h = Handler(io.println, on_hover: fn() { Nil })
  h.on_click()
}"
  let result = parse_and_extract(src)
  // Positional fills on_click (first field); labelled on_hover is a
  // closure so field resolution picks up only the on_click call.
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn qualified_constructor_field_call_resolves_test() {
  let src =
    "import gleam/io
import other
pub fn target() {
  let v = other.Validator(to_error: io.println)
  v.to_error(1)
}"
  let result = parse_and_extract(src)
  result.resolved
  |> list.map(fn(r) { r.name })
  |> should.equal([QualifiedName("gleam/io", "println")])
}

pub fn alias_as_argument_classified_as_function_ref_test() {
  let src =
    "import gleam/io
import gleam/list
pub fn target(xs) {
  let f = io.println
  list.map(xs, f)
}"
  let result = parse_and_extract(src)
  // Confirm list.map resolves and its second arg is classified as a
  // function ref to io.println (drives effect-variable binding).
  let assert Ok(call) =
    list.find(result.resolved, fn(r) {
      r.name == QualifiedName("gleam/list", "map")
    })
  let assert Ok(args) = dict.get(result.call_args, call.span.start)
  let assert Ok(second_arg) = list.find(args, fn(a) { a.position == 1 })
  second_arg.value
  |> should.equal(FunctionRef(QualifiedName("gleam/io", "println")))
}
