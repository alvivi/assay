import glance
import gleam/option.{None, Some}
import gleam/set
import gleeunit/should
import graded/internal/signatures
import graded/internal/types.{QualifiedName}

// ──── JSON parsing ────

pub fn parse_empty_modules_test() {
  let json = "{\"name\":\"pkg\",\"modules\":{}}"
  let assert Ok(registry) = signatures.from_json_string(json)
  signatures.lookup(registry, QualifiedName("anything", "foo"))
  |> should.equal(None)
}

pub fn parse_named_type_param_is_not_fn_typed_test() {
  let json =
    "{\"modules\":{\"myapp\":{\"functions\":{\"greet\":{\"parameters\":[{\"label\":\"name\",\"type\":{\"kind\":\"named\",\"name\":\"String\"}}]}}}}}"
  let assert Ok(registry) = signatures.from_json_string(json)
  let assert Some(params) =
    signatures.lookup(registry, QualifiedName("myapp", "greet"))
  params
  |> should.equal([
    signatures.ParameterInfo(
      position: 0,
      label: Some("name"),
      is_fn_typed: False,
    ),
  ])
}

pub fn parse_fn_typed_param_test() {
  let json =
    "{\"modules\":{\"gleam/list\":{\"functions\":{\"map\":{\"parameters\":[{\"label\":null,\"type\":{\"kind\":\"named\",\"name\":\"List\"}},{\"label\":null,\"type\":{\"kind\":\"fn\",\"parameters\":[],\"return\":{\"kind\":\"variable\",\"id\":0}}}]}}}}}"
  let assert Ok(registry) = signatures.from_json_string(json)
  let assert Some(params) =
    signatures.lookup(registry, QualifiedName("gleam/list", "map"))
  params
  |> should.equal([
    signatures.ParameterInfo(position: 0, label: None, is_fn_typed: False),
    signatures.ParameterInfo(position: 1, label: None, is_fn_typed: True),
  ])
}

pub fn fn_typed_param_names_returns_labeled_fn_params_test() {
  let json =
    "{\"modules\":{\"myapp\":{\"functions\":{\"validate_range\":{\"parameters\":[{\"label\":\"value\",\"type\":{\"kind\":\"named\",\"name\":\"Int\"}},{\"label\":\"to_error\",\"type\":{\"kind\":\"fn\",\"parameters\":[],\"return\":{\"kind\":\"variable\",\"id\":0}}}]}}}}}"
  let assert Ok(registry) = signatures.from_json_string(json)
  signatures.fn_typed_param_names(
    registry,
    QualifiedName("myapp", "validate_range"),
  )
  |> should.equal(set.from_list(["to_error"]))
}

pub fn missing_function_returns_none_test() {
  let json = "{\"modules\":{}}"
  let assert Ok(registry) = signatures.from_json_string(json)
  signatures.lookup(registry, QualifiedName("nope", "gone"))
  |> should.equal(None)
  signatures.fn_typed_param_names(registry, QualifiedName("nope", "gone"))
  |> should.equal(set.new())
}

pub fn merge_combines_registries_test() {
  let json_a =
    "{\"modules\":{\"a\":{\"functions\":{\"foo\":{\"parameters\":[]}}}}}"
  let json_b =
    "{\"modules\":{\"b\":{\"functions\":{\"bar\":{\"parameters\":[]}}}}}"
  let assert Ok(ra) = signatures.from_json_string(json_a)
  let assert Ok(rb) = signatures.from_json_string(json_b)
  let merged = signatures.merge(ra, rb)
  signatures.lookup(merged, QualifiedName("a", "foo")) |> should.equal(Some([]))
  signatures.lookup(merged, QualifiedName("b", "bar")) |> should.equal(Some([]))
}

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
