import assay/effects.{type KnowledgeBase}
import assay/extract.{type ImportContext}
import assay/types.{
  type EffectAnnotation, type ParamBound, type Violation, EffectAnnotation,
  Effects, QualifiedName, Violation,
}
import glance.{type Definition, type Function, type Module}
import gleam/option.{Some}
import gleam/dict
import gleam/list
import gleam/set.{type Set}

/// Check a parsed module against its effect annotations.
pub fn check(
  module: Module,
  annotations: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
) -> List(Violation) {
  let context = extract.build_import_context(module)
  let function_map = build_function_map(module)

  list.flat_map(annotations, fn(annotation) {
    check_annotation(annotation, function_map, context, knowledge_base)
  })
}

/// Infer the effect set for every public function in a module.
pub fn infer(
  module: Module,
  knowledge_base: KnowledgeBase,
) -> List(EffectAnnotation) {
  let context = extract.build_import_context(module)
  let function_map = build_function_map(module)

  module.functions
  |> list.filter(fn(definition) {
    definition.definition.publicity == glance.Public
  })
  |> list.map(fn(definition) {
    let all_effects =
      collect_effects(
        definition.definition,
        function_map,
        context,
        knowledge_base,
        set.new(),
        [],
      )
    let effect_set =
      list.fold(all_effects, set.new(), fn(combined, pair) {
        set.union(combined, pair.1)
      })
    EffectAnnotation(
      kind: Effects,
      function: definition.definition.name,
      params: [],
      effects: effect_set,
    )
  })
}

// PRIVATE

fn build_function_map(module: Module) -> dict.Dict(String, Definition(Function)) {
  module.functions
  |> list.map(fn(definition) { #(definition.definition.name, definition) })
  |> dict.from_list()
}

fn check_annotation(
  annotation: EffectAnnotation,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> List(Violation) {
  case dict.get(function_map, annotation.function) {
    Error(Nil) -> []
    Ok(function_definition) -> {
      let body_effects =
        collect_effects(
          function_definition.definition,
          function_map,
          context,
          knowledge_base,
          set.new(),
          annotation.params,
        )
      body_effects
      |> list.filter(fn(pair) {
        let #(_, call_effects) = pair
        !set.is_subset(call_effects, of: annotation.effects)
      })
      |> list.map(fn(pair) {
        let #(call, call_effects) = pair
        Violation(
          function: annotation.function,
          call: call.name,
          span: call.span,
          declared: annotation.effects,
          actual: call_effects,
        )
      })
    }
  }
}

fn collect_effects(
  function: Function,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  param_bounds: List(ParamBound),
) -> List(#(types.ResolvedCall, Set(String))) {
  let result = extract.extract_calls(function.body, context)

  let resolved_effects =
    list.map(result.resolved, fn(call) {
      #(call, effects.lookup_effects(knowledge_base, call.name))
    })

  let local_effects =
    list.flat_map(result.local, fn(local_call) {
      case list.find(param_bounds, fn(p) { p.name == local_call.function }) {
        Ok(bound) -> {
          let synthetic_call =
            types.ResolvedCall(
              name: QualifiedName(
                module: "<param>",
                function: local_call.function,
              ),
              span: local_call.span,
            )
          [#(synthetic_call, bound.effects)]
        }
        Error(Nil) ->
          case set.contains(visited, local_call.function) {
            True -> []
            False ->
              case dict.get(function_map, local_call.function) {
                Error(Nil) -> {
                  let synthetic_call =
                    types.ResolvedCall(
                      name: QualifiedName(
                        module: "<local>",
                        function: local_call.function,
                      ),
                      span: local_call.span,
                    )
                  [#(synthetic_call, set.from_list(["Unknown"]))]
                }
                Ok(local_definition) -> {
                  let new_visited = set.insert(visited, local_call.function)
                  collect_effects(
                    local_definition.definition,
                    function_map,
                    context,
                    knowledge_base,
                    new_visited,
                    [],
                  )
                }
              }
          }
      }
    })

  let field_effects =
    list.map(result.field, fn(field_call) {
      let synthetic_call =
        types.ResolvedCall(
          name: QualifiedName(
            module: "<field>",
            function: field_call.object <> "." <> field_call.label,
          ),
          span: field_call.span,
        )
      let effect_set = resolve_field_call(field_call, function, knowledge_base)
      #(synthetic_call, effect_set)
    })

  list.flatten([resolved_effects, local_effects, field_effects])
}

fn resolve_field_call(
  field_call: types.FieldCall,
  function: Function,
  knowledge_base: KnowledgeBase,
) -> Set(String) {
  let unknown = set.from_list(["Unknown"])
  let param =
    list.find(function.parameters, fn(p) {
      case p.name {
        glance.Named(name) -> name == field_call.object
        glance.Discarded(_) -> False
      }
    })
  case param {
    Ok(glance.FunctionParameter(
      type_: Some(glance.NamedType(name: type_name, ..)),
      ..,
    )) ->
      case effects.lookup_type_field(knowledge_base, type_name, field_call.label) {
        effects.Known(effect_set) -> effect_set
        effects.Unknown -> unknown
      }
    _ -> unknown
  }
}
