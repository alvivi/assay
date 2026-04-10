import generators
import glance
import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/set
import gleam/string
import gleeunit/should
import graded/internal/checker
import graded/internal/effects
import graded/internal/types.{
  type EffectAnnotation, type EffectSet, Check, EffectAnnotation, Effects,
  ParamBound, QualifiedName, Specific, UntrackedEffectWarning, Wildcard,
}
import qcheck

fn knowledge_base() -> effects.KnowledgeBase {
  effects.empty_knowledge_base()
}

fn check_source(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Violation) {
  let assert Ok(module) = glance.module(source)
  let #(violations, _warnings) =
    checker.check(module, annotations, knowledge_base())
  violations
}

pub fn pure_function_passes_test() {
  let source =
    "import gleam/list
pub fn view(items) { list.map(items, fn(x) { x }) }"
  check_source(source, [
    EffectAnnotation(Check, "view", [], Specific(set.new())),
  ])
  |> should.equal([])
}

pub fn effectful_call_in_pure_function_fails_test() {
  let source =
    "import gleam/io
pub fn view() { io.println(\"oops\") }"
  let violations =
    check_source(source, [
      EffectAnnotation(Check, "view", [], Specific(set.new())),
    ])
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
    EffectAnnotation(Check, "log", [], Specific(set.from_list(["Stdout"]))),
  ])
  |> should.equal([])
}

pub fn transitive_violation_test() {
  let source =
    "import gleam/io
pub fn view() { helper() }
fn helper() { io.println(\"sneaky\") }"
  let violations =
    check_source(source, [
      EffectAnnotation(Check, "view", [], Specific(set.new())),
    ])
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
      EffectAnnotation(
        Check,
        "do_stuff",
        [],
        Specific(set.from_list(["Stdout"])),
      ),
    ])
  violations
  |> list.any(fn(violation) { violation.call.function == "sleep" })
  |> should.be_true()
}

pub fn missing_function_ignored_test() {
  let source = "pub fn other() { Nil }"
  check_source(source, [
    EffectAnnotation(Check, "nonexistent", [], Specific(set.new())),
  ])
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
    check_source(source, [
      EffectAnnotation(Check, "view", [], Specific(set.new())),
    ])
  { violations != [] } |> should.be_true()
}

pub fn unknown_local_function_test() {
  // Function "missing" is referenced but not defined in the module
  let source = "pub fn view() { missing() }"
  let violations =
    check_source(source, [
      EffectAnnotation(Check, "view", [], Specific(set.new())),
    ])
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
  annotation.effects |> should.equal(Specific(set.new()))
}

pub fn infer_effectful_function_test() {
  let source =
    "import gleam/io
pub fn greet() { io.println(\"hi\") }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base(), [])
  let assert [annotation] = inferred
  annotation.effects |> should.equal(Specific(set.from_list(["Stdout"])))
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
      [ParamBound("f", Specific(set.from_list(["Stdout"])))],
      Specific(set.from_list(["Stdout"])),
    ),
  ]
  let inferred = checker.infer(module, knowledge_base(), existing_checks)
  let assert [annotation] = inferred
  annotation.effects |> should.equal(Specific(set.from_list(["Stdout"])))
}

pub fn infer_without_bounds_gets_unknown_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let assert Ok(module) = glance.module(source)
  let inferred = checker.infer(module, knowledge_base(), [])
  let assert [annotation] = inferred
  annotation.effects |> should.equal(Specific(set.from_list(["Unknown"])))
}

// Higher-order / parameter bound tests

// Case 1: function that calls a parameter — effects come from the declared bound
pub fn param_call_uses_bound_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let annotation =
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", Specific(set.from_list(["Stdout"])))],
      Specific(set.from_list(["Stdout"])),
    )
  check_source(source, [annotation]) |> should.equal([])
}

// Case 1b: undeclared param call treated as Unknown, violates pure bound
pub fn param_call_without_bound_is_unknown_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  check_source(source, [
    EffectAnnotation(Check, "apply", [], Specific(set.new())),
  ])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Case 2: declared bound of [] means param must be pure — pure arg passes
pub fn param_bound_pure_passes_test() {
  let source =
    "import gleam/list
pub fn safe_map(items, f) { list.map(items, f) }"
  let annotation =
    EffectAnnotation(
      Check,
      "safe_map",
      [ParamBound("f", Specific(set.new()))],
      Specific(set.new()),
    )
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
  let annotation =
    EffectAnnotation(Check, "run", [], Specific(set.from_list(["Stdout"])))
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
  check_source(source, [EffectAnnotation(Check, "run", [], Specific(set.new()))])
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
  let #(violations, _warnings) = checker.check(module, annotations, kb)
  violations
}

// Typed param + registry entry → effects resolve correctly
pub fn field_call_typed_with_registry_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.TypeFieldAnnotation(
      module: None,
      type_name: "Handler",
      field: "on_click",
      effects: Specific(set.from_list(["Dom"])),
    ),
  ]
  let annotation =
    EffectAnnotation(Check, "view", [], Specific(set.from_list(["Dom"])))
  check_source_with_type_fields(source, [annotation], type_fields)
  |> should.equal([])
}

// Field effects exceed declared budget → violation
pub fn field_call_violates_check_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let type_fields = [
    types.TypeFieldAnnotation(
      module: None,
      type_name: "Handler",
      field: "on_click",
      effects: Specific(set.from_list(["Dom"])),
    ),
  ]
  let annotation = EffectAnnotation(Check, "view", [], Specific(set.new()))
  check_source_with_type_fields(source, [annotation], type_fields)
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Typed param but no registry entry → Unknown
pub fn field_call_typed_no_registry_is_unknown_test() {
  let source = "pub fn view(handler: Handler) { handler.on_click(event) }"
  let annotation = EffectAnnotation(Check, "view", [], Specific(set.new()))
  check_source_with_type_fields(source, [annotation], [])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Untyped param → Unknown
pub fn field_call_untyped_is_unknown_test() {
  let source = "pub fn view(handler) { handler.on_click(event) }"
  let annotation = EffectAnnotation(Check, "view", [], Specific(set.new()))
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
  let #(violations, _warnings) = checker.check(module, annotations, kb)
  violations
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
      Specific(set.from_list(["Http"])),
    ),
  ]
  let annotation =
    EffectAnnotation(Check, "fetch", [], Specific(set.from_list(["Http"])))
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
      Specific(set.from_list(["Http"])),
    ),
  ]
  let annotation = EffectAnnotation(Check, "fetch", [], Specific(set.new()))
  check_source_with_externals(source, [annotation], externals)
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// Wildcard [_] tests

pub fn wildcard_declared_passes_all_effects_test() {
  let source =
    "import gleam/io
pub fn handler() { io.println(\"hi\") }"
  check_source(source, [EffectAnnotation(Check, "handler", [], Wildcard)])
  |> should.equal([])
}

pub fn wildcard_param_bound_passes_test() {
  let source = "pub fn apply(f, x) { f(x) }"
  let annotation =
    EffectAnnotation(Check, "apply", [ParamBound("f", Wildcard)], Wildcard)
  check_source(source, [annotation]) |> should.equal([])
}

pub fn wildcard_param_bound_in_pure_function_violates_test() {
  // f has wildcard effects but function declares []
  let source = "pub fn apply(f, x) { f(x) }"
  let annotation =
    EffectAnnotation(
      Check,
      "apply",
      [ParamBound("f", Wildcard)],
      Specific(set.new()),
    )
  check_source(source, [annotation])
  |> { fn(vs) { vs != [] } }
  |> should.be_true()
}

// ──── Function Reference Warnings ────

fn check_warnings(
  source: String,
  annotations: List(EffectAnnotation),
) -> List(types.Warning) {
  let assert Ok(module) = glance.module(source)
  let #(_violations, warnings) =
    checker.check(module, annotations, knowledge_base())
  warnings
}

// Qualified function reference passed as value emits warning
pub fn function_ref_qualified_warns_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn greet_all(names) { list.map(names, io.println) }"
  let warnings =
    check_warnings(source, [
      EffectAnnotation(Check, "greet_all", [], Specific(set.new())),
    ])
  warnings |> list.length() |> should.equal(1)
  let assert [warning] = warnings
  let UntrackedEffectWarning(function:, reference:, effects:, ..) = warning
  function |> should.equal("greet_all")
  reference |> should.equal(QualifiedName("gleam/io", "println"))
  effects |> should.equal(Specific(set.from_list(["Stdout"])))
}

// Unqualified function reference passed as value emits warning
pub fn function_ref_unqualified_warns_test() {
  let source =
    "import gleam/io.{println}
import gleam/list
pub fn greet_all(names) { list.map(names, println) }"
  let warnings =
    check_warnings(source, [
      EffectAnnotation(Check, "greet_all", [], Specific(set.new())),
    ])
  warnings |> list.length() |> should.equal(1)
  let assert [warning] = warnings
  let UntrackedEffectWarning(reference:, ..) = warning
  reference |> should.equal(QualifiedName("gleam/io", "println"))
}

// Pure function reference does not emit warning
pub fn function_ref_pure_no_warning_test() {
  let source =
    "import gleam/list
import gleam/string
pub fn upper_all(items) { list.map(items, string.uppercase) }"
  check_warnings(source, [
    EffectAnnotation(Check, "upper_all", [], Specific(set.new())),
  ])
  |> should.equal([])
}

// Unknown function reference does not emit warning
pub fn function_ref_unknown_no_warning_test() {
  let source =
    "import some/unknown
import gleam/list
pub fn run(items) { list.map(items, unknown.do_thing) }"
  check_warnings(source, [
    EffectAnnotation(Check, "run", [], Specific(set.new())),
  ])
  |> should.equal([])
}

// Inline closure does not emit warning (effects tracked normally)
pub fn inline_closure_no_warning_test() {
  let source =
    "import gleam/io
import gleam/list
pub fn greet_all(names) { list.map(names, fn(n) { io.println(n) }) }"
  check_warnings(source, [
    EffectAnnotation(
      Check,
      "greet_all",
      [],
      Specific(set.from_list(["Stdout"])),
    ),
  ])
  |> should.equal([])
}

// ──── Checker Soundness (property) ────

const call_pool = [
  #("mod_a", "call_http", "Http"),
  #("mod_b", "call_dom", "Dom"),
  #("mod_c", "call_stdout", "Stdout"),
  #("mod_d", "call_db", "Db"),
  #("mod_e", "call_fs", "FileSystem"),
]

fn call_selection_gen() -> qcheck.Generator(List(Bool)) {
  qcheck.fixed_length_list_from(qcheck.bool(), list.length(call_pool))
}

fn selected_calls(selections: List(Bool)) -> List(#(String, String, String)) {
  list.zip(call_pool, selections)
  |> list.filter_map(fn(pair) {
    case pair.1 {
      True -> Ok(pair.0)
      False -> Error(Nil)
    }
  })
}

fn build_module(
  calls: List(#(String, String, String)),
) -> Result(glance.Module, Nil) {
  let modules =
    calls
    |> list.map(fn(c) { c.0 })
    |> list.unique()
    |> list.sort(string.compare)
  let imports =
    modules |> list.map(fn(m) { "import " <> m }) |> string.join("\n")
  let body = case calls {
    [] -> "  Nil"
    _ ->
      calls
      |> list.map(fn(c) { "  " <> c.0 <> "." <> c.1 <> "()" })
      |> string.join("\n")
  }
  let source = imports <> "\npub fn test_fn() {\n" <> body <> "\n}\n"
  glance.module(source) |> result.replace_error(Nil)
}

fn build_kb(calls: List(#(String, String, String))) -> effects.KnowledgeBase {
  let all_effects =
    calls
    |> list.map(fn(c) {
      #(
        types.QualifiedName(module: c.0, function: c.1),
        types.from_labels([c.2]),
      )
    })
    |> dict.from_list()
  effects.KnowledgeBase(
    all_effects:,
    param_bounds: dict.new(),
    type_fields: dict.new(),
    pure_modules: set.new(),
  )
}

fn actual_effects(calls: List(#(String, String, String))) -> EffectSet {
  calls |> list.map(fn(c) { c.2 }) |> types.from_labels()
}

pub fn check_no_false_positives_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let declared = actual_effects(calls)
      let ann = EffectAnnotation(Check, "test_fn", [], declared)
      let #(violations, _) = checker.check(module, [ann], kb)
      violations |> should.equal([])
    }
  }
}

pub fn check_wildcard_never_violates_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let ann = EffectAnnotation(Check, "test_fn", [], Wildcard)
      let #(violations, _) = checker.check(module, [ann], kb)
      violations |> should.equal([])
    }
  }
}

pub fn check_empty_budget_detects_effects_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case calls {
    [] -> Nil
    _ ->
      case build_module(calls) {
        Error(Nil) -> Nil
        Ok(module) -> {
          let kb = build_kb(calls)
          let ann = EffectAnnotation(Check, "test_fn", [], types.empty())
          let #(violations, _) = checker.check(module, [ann], kb)
          { violations != [] } |> should.be_true()
        }
      }
  }
}

pub fn check_violations_iff_not_subset_test() {
  use #(selections, declared) <- qcheck.given(
    qcheck.map2(call_selection_gen(), generators.effect_set_gen(), fn(s, d) {
      #(s, d)
    }),
  )
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let ann = EffectAnnotation(Check, "test_fn", [], declared)
      let #(violations, _) = checker.check(module, [ann], kb)
      let has_violations = violations != []
      let actual = actual_effects(calls)
      let not_subset = !types.is_subset(actual, declared)
      has_violations |> should.equal(not_subset)
    }
  }
}

pub fn infer_matches_actual_effects_test() {
  use selections <- qcheck.given(call_selection_gen())
  let calls = selected_calls(selections)
  case build_module(calls) {
    Error(Nil) -> Nil
    Ok(module) -> {
      let kb = build_kb(calls)
      let inferred = checker.infer(module, kb, [])
      let assert [ann] = inferred
      ann.function |> should.equal("test_fn")
      ann.effects |> should.equal(actual_effects(calls))
    }
  }
}

// ──── Cycle Detection (property) ────

fn cycle_graph_gen() -> qcheck.Generator(List(#(String, List(String)))) {
  let names = ["a", "b", "c", "d"]
  let callees_gen =
    qcheck.map(
      qcheck.fixed_length_list_from(qcheck.bool(), list.length(names)),
      fn(bools) {
        list.zip(names, bools)
        |> list.filter_map(fn(pair) {
          case pair.1 {
            True -> Ok(pair.0)
            False -> Error(Nil)
          }
        })
      },
    )
  qcheck.map(
    qcheck.fixed_length_list_from(callees_gen, list.length(names)),
    fn(all_callees) { list.zip(names, all_callees) },
  )
}

fn build_cycle_source(graph: List(#(String, List(String)))) -> String {
  graph
  |> list.index_map(fn(entry, i) {
    let #(name, callees) = entry
    let visibility = case i {
      0 -> "pub "
      _ -> ""
    }
    let body = case callees {
      [] -> "  Nil"
      cs -> cs |> list.map(fn(c) { "  " <> c <> "()" }) |> string.join("\n")
    }
    visibility <> "fn " <> name <> "() {\n" <> body <> "\n}"
  })
  |> string.join("\n")
}

fn bare_knowledge_base() -> effects.KnowledgeBase {
  effects.KnowledgeBase(
    all_effects: dict.new(),
    param_bounds: dict.new(),
    type_fields: dict.new(),
    pure_modules: set.new(),
  )
}

pub fn infer_terminates_with_cycles_test() {
  use graph <- qcheck.given(cycle_graph_gen())
  let source = build_cycle_source(graph)
  case glance.module(source) {
    Error(_) -> Nil
    Ok(module) -> {
      let inferred = checker.infer(module, bare_knowledge_base(), [])
      let assert [ann] = inferred
      ann.function |> should.equal("a")
    }
  }
}

pub fn check_terminates_with_cycles_test() {
  use graph <- qcheck.given(cycle_graph_gen())
  let source = build_cycle_source(graph)
  case glance.module(source) {
    Error(_) -> Nil
    Ok(module) -> {
      let ann = EffectAnnotation(Check, "a", [], types.empty())
      let #(violations, _) = checker.check(module, [ann], bare_knowledge_base())
      violations |> should.equal([])
    }
  }
}
