import assay/internal/checker
import assay/internal/effects
import assay/internal/types.{
  type EffectAnnotation, Check, EffectAnnotation, Effects, ParamBound,
  QualifiedName,
}
import glance
import gleam/list
import gleam/set
import gleeunit/should

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

fn check_source(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  checker.check(module, annotations, knowledge_base())
}

pub fn pure_function_passes_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  check_source(source, [EffectAnnotation(Check, "view", [], set.new())])
  |> should.equal([])
}

pub fn effectful_call_in_pure_function_fails_test() {
  let source =
    "import gleam/io
pub fn view() { io.println(\"oops\") }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", [], set.new())])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.function |> should.equal("view")
  violation.call |> should.equal(QualifiedName("gleam/io", "println"))
}

pub fn declared_effects_pass_test() {
  let source =
    "import gleam/io
pub fn log(msg) { io.println(msg) }"
  check_source(source, [
    EffectAnnotation(Check, "log", [], set.from_list(["Stdout"])),
  ])
  |> should.equal([])
}

pub fn transitive_violation_test() {
  let source =
    "import gleam/io
pub fn view() { helper() }
fn helper() { io.println(\"sneaky\") }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", [], set.new())])
  violations |> list.length() |> should.equal(1)
  let assert [violation] = violations
  violation.call |> should.equal(QualifiedName("gleam/io", "println"))
}

pub fn multiple_effects_union_test() {
  let source =
    "import gleam/io
import gleam/erlang/process
pub fn do_stuff() {
  io.println(\"hi\")
  process.sleep(100)
}"
  let violations =
    check_source(source, [
      EffectAnnotation(Check, "do_stuff", [], set.from_list(["Stdout"])),
    ])
  violations
  |> list.any(fn(violation) { violation.call.function == "sleep" })
  |> should.be_true()
}

pub fn missing_function_ignored_test() {
  let source = "pub fn other() { Nil }"
  check_source(source, [EffectAnnotation(Check, "nonexistent", [], set.new())])
  |> should.equal([])
}

pub fn closure_effects_contribute_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn view(items) {
  list.map(items, fn(x) { io.println(x) })
}"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", [], set.new())])
  { violations != [] } |> should.be_true()
}

pub fn mutual_recursion_cycle_test() {
  let source =
    "pub fn a() { b() }
fn b() { a() }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "a", [], set.new())])
  // Should not infinite loop. Both are local with no external calls, so pure.
  violations |> should.equal([])
}

pub fn unknown_local_function_test() {
  // Function "missing" is referenced but not defined in the module
  let source = "pub fn view() { missing() }"
  let violations =
    check_source(source, [EffectAnnotation(Check, "view", [], set.new())])
  // Should flag as Unknown effect
  { violations != [] } |> should.be_true()
  let assert [violation] = violations
  violation.call.function |> should.equal("missing")
}

// Infer

pub fn infer_pure_function_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base(), [])
  let assert [annotation] = inferred
  annotation.kind |> should.equal(Effects)
  annotation.function |> should.equal("view")
  set.size(annotation.effects) |> should.equal(0)
}

pub fn infer_effectful_function_test() {
  let source =
    "import gleam/io
pub fn greet() { io.println(\"hi\") }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base(), [])
  let assert [annotation] = inferred
  annotation.effects |> should.equal(set.from_list(["Stdout"]))
}

pub fn infer_only_public_functions_test() {
  let source =
    "import gleam/io
pub fn view() { helper() }
fn helper() { io.println(\"x\") }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base(), [])
  let assert [annotation] = inferred
  annotation.function |> should.equal("view")
}

// Infer respects existing param bounds

pub fn infer_uses_param_bounds_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let assert Ok(module) = glance.module(source)
  let existing_checks = [
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", set.from_list(["Stdout"]))],
      set.from_list(["Stdout"]),
    ),
  ]
  let inferred = checker.infer(module, knowledge_base(), existing_checks)
  let assert [annotation] = inferred
  annotation.effects |> should.equal(set.from_list(["Stdout"]))
}

pub fn infer_without_bounds_gets_unknown_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base(), [])
  let assert [annotation] = inferred
  annotation.effects |> should.equal(set.from_list(["Unknown"]))
}

// Higher-order / parameter bound tests

// Case 1: function that calls a parameter — effects come from the declared bound
pub fn param_call_uses_bound_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let annotation =
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", set.from_list(["Stdout"]))],
      set.from_list(["Stdout"]),
    )
  check_source(source, [annotation]) |> should.equal([])
}

// Case 1b: undeclared param call treated as Unknown, violates pure bound
pub fn param_call_without_bound_is_unknown_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  check_source(source, [EffectAnnotation(Check, "apply", [], set.new())])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Case 2: declared bound of [] means param must be pure — pure arg passes
pub fn param_bound_pure_passes_test() {
  let source =
    "import gleam/list
pub fn safe_map(items, f) { list.map(items, f) }"
  let annotation =
    EffectAnnotation(Check, "safe_map", [ParamBound("f", set.new())], set.new())
  check_source(source, [annotation]) |> should.equal([])
}

// Case 3: inline closure effects propagate to enclosing function via flattening
pub fn inline_closure_effects_propagate_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn run(items) {
  list.map(items, fn(x) { io.println(x) })
}"
  let annotation = EffectAnnotation(Check, "run", [], set.from_list(["Stdout"]))
  check_source(source, [annotation]) |> should.equal([])
}

// Case 3b: inline closure with effects violates a pure check
pub fn inline_closure_effects_violate_pure_check_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn run(items) {
  list.map(items, fn(x) { io.println(x) })
}"
  check_source(source, [EffectAnnotation(Check, "run", [], set.new())])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Field call tests (Case 4)

fn check_source_with_type_fields(
  source: String,
  annotations: List(EffectAnnotation),
  type_fields: List(types.TypeFieldAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let kb = effects.with_type_fields(knowledge_base(), type_fields)
  checker.check(module, annotations, kb)
}

// Typed param + registry entry → effects resolve correctly
pub fn field_call_typed_with_registry_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.TypeFieldAnnotation("Handler", "on_click", set.from_list(["Dom"])),
  ]
  let annotation = EffectAnnotation(Check, "view", [], set.from_list(["Dom"]))
  check_source_with_type_fields(source, [annotation], type_fields)
  |> should.equal([])
}

// Field effects exceed declared budget → violation
pub fn field_call_violates_check_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.TypeFieldAnnotation("Handler", "on_click", set.from_list(["Dom"])),
  ]
  let annotation = EffectAnnotation(Check, "view", [], set.new())
  check_source_with_type_fields(source, [annotation], type_fields)
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Typed param but no registry entry → Unknown
pub fn field_call_typed_no_registry_is_unknown_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let annotation = EffectAnnotation(Check, "view", [], set.new())
  check_source_with_type_fields(source, [annotation], [])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Untyped param → Unknown
pub fn field_call_untyped_is_unknown_test() {
  let source = "pub fn view(handler) { handler.on_click(event) }"
  let annotation = EffectAnnotation(Check, "view", [], set.new())
  check_source(source, [annotation])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// External declaration tests

fn check_source_with_externals(
  source: String,
  annotations: List(EffectAnnotation),
  externals: List(types.ExternalAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let kb = effects.with_externals(knowledge_base(), externals)
  checker.check(module, annotations, kb)
}

// External resolves instead of Unknown
pub fn external_resolves_effects_test() {
  let source =
    "import gleam/httpc
pub fn fetch() { httpc.send(request) }"
  let externals = [
    types.ExternalAnnotation(
      "gleam/httpc",
      types.FunctionExternal("send"),
      set.from_list(["Http"]),
    ),
  ]
  let annotation = EffectAnnotation(Check, "fetch", [], set.from_list(["Http"]))
  check_source_with_externals(source, [annotation], externals)
  |> should.equal([])
}

// External effect exceeds budget → violation
pub fn external_violates_check_test() {
  let source =
    "import gleam/httpc
pub fn fetch() { httpc.send(request) }"
  let externals = [
    types.ExternalAnnotation(
      "gleam/httpc",
      types.FunctionExternal("send"),
      set.from_list(["Http"]),
    ),
  ]
  let annotation = EffectAnnotation(Check, "fetch", [], set.new())
  check_source_with_externals(source, [annotation], externals)
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}
