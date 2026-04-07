import assay/internal/effects.{type KnowledgeBase}
import assay/internal/extract.{type ImportContext}
import assay/internal/types.{
  type EffectAnnotation, type LocalCall, type ParamBound, type ResolvedCall,
  type Violation, EffectAnnotation, Effects, QualifiedName, Violation,
}
import glance.{type Definition, type Function, type Module}
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
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
/// Pass existing `check` annotations so their param bounds are used during inference.
pub fn infer(
  module: Module,
  knowledge_base: KnowledgeBase,
  existing_checks: List(EffectAnnotation),
) -> List(EffectAnnotation) {
  let context = extract.build_import_context(module)
  let function_map = build_function_map(module)

  // Seed param bounds from existing `check` annotations only — `effects`
  // annotations don't carry user-declared bounds, so they can't constrain
  // higher-order parameters during inference.
  let bounds_map =
    existing_checks
    |> list.filter(fn(annotation) { annotation.params != [] })
    |> list.map(fn(annotation) { #(annotation.function, annotation.params) })
    |> dict.from_list()

  module.functions
  |> list.filter(fn(definition) {
    definition.definition.publicity == glance.Public
  })
  |> list.map(fn(definition) {
    let param_bounds =
      dict.get(bounds_map, definition.definition.name)
      |> result.unwrap([])
    let all_effects =
      collect_effects(
        definition.definition,
        function_map,
        context,
        knowledge_base,
        set.new(),
        param_bounds,
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
    // Silently skip: the annotation may be stale or apply to a different
    // build target. Missing functions are not an error.
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
      // A call is a violation when its effect set is not a subset of the
      // declared budget — i.e. it performs effects the caller didn't allow.
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

// Collect all (call, effect_set) pairs reachable from a function body.
// Calls fall into three categories:
//   resolved — qualified module.function calls, looked up in the knowledge base
//   local    — unqualified calls, resolved via param bounds or transitive analysis
//   field    — object.method calls, resolved via type field annotations
// `visited` tracks functions already on the call stack for cycle detection.
fn collect_effects(
  function: Function,
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  visited: Set(String),
  param_bounds: List(ParamBound),
) -> List(#(types.ResolvedCall, Set(String))) {
  let result = extract.extract_calls(function.body, context)

  // Resolved calls: qualified names looked up directly in the knowledge base.
  let resolved_effects =
    list.map(result.resolved, fn(call) {
      #(call, effects.lookup_effects(knowledge_base, call.name))
    })

  // Local calls: check param bounds first (higher-order function parameters),
  // then fall back to transitive analysis of local definitions.
  let local_effects =
    list.flat_map(result.local, fn(local_call) {
      case
        list.find(param_bounds, fn(param) { param.name == local_call.function })
      {
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
          resolve_unknown_local(
            local_call,
            visited,
            function_map,
            context,
            knowledge_base,
          )
      }
    })

  // Field calls: object.method(args) resolved via type field annotations.
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

fn resolve_unknown_local(
  local_call: LocalCall,
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
) -> List(#(ResolvedCall, Set(String))) {
  case set.contains(visited, local_call.function) {
    // Cycle detected — already analysing this function up the call stack.
    // Return empty rather than looping; the effects will be captured by the
    // outer frame that started the analysis.
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

fn resolve_field_call(
  field_call: types.FieldCall,
  function: Function,
  knowledge_base: KnowledgeBase,
) -> Set(String) {
  let unknown = set.from_list(["Unknown"])
  let param =
    list.find(function.parameters, fn(param) {
      case param.name {
        glance.Named(name) -> name == field_call.object
        glance.Discarded(_) -> False
      }
    })
  case param {
    Ok(glance.FunctionParameter(
      type_: Some(glance.NamedType(name: type_name, ..)),
      ..,
    )) ->
      case
        effects.lookup_type_field(knowledge_base, type_name, field_call.label)
      {
        effects.Known(effect_set) -> effect_set
        effects.Unknown -> unknown
      }
    _ -> unknown
  }
}
