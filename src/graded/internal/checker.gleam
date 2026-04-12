import glance.{type Definition, type Function, type Module}
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/extract.{type ImportContext}
import graded/internal/signatures.{type SignatureRegistry}
import graded/internal/types.{
  type EffectAnnotation, type EffectSet, type LocalCall, type ParamBound,
  type ResolvedCall, type Violation, type Warning, EffectAnnotation, Effects,
  ParamBound, Polymorphic, QualifiedName, UntrackedEffectWarning, Violation,
}

/// Check a parsed module against its effect annotations.
pub fn check(
  module: Module,
  annotations: List(EffectAnnotation),
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
) -> #(List(Violation), List(Warning)) {
  let context = extract.build_import_context(module)
  let function_map = build_function_map(module)

  let results =
    list.map(annotations, fn(annotation) {
      check_annotation(
        annotation,
        function_map,
        context,
        knowledge_base,
        registry,
      )
    })
  let violations = list.flat_map(results, fn(r) { r.0 })
  let warnings = list.flat_map(results, fn(r) { r.1 })
  #(violations, warnings)
}

/// Infer the effect set for every public function in a module.
/// Pass existing `check` annotations so their param bounds are used during inference.
pub fn infer(
  module: Module,
  knowledge_base: KnowledgeBase,
  existing_checks: List(EffectAnnotation),
  registry: SignatureRegistry,
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
    // Auto-detect fn-typed parameters from glance type annotations so
    // calls to them produce effect variables instead of [Unknown].
    // Parameters that already have a user-declared bound take priority
    // and are excluded from auto-detection.
    let declared_bound_names =
      param_bounds |> list.map(fn(b) { b.name }) |> set.from_list()
    let fn_typed_params =
      signatures.fn_typed_params_from_function(definition.definition)
      |> set.filter(fn(name) { !set.contains(declared_bound_names, name) })
    let all_effects =
      collect_effects(
        definition.definition,
        function_map,
        context,
        knowledge_base,
        set.new(),
        param_bounds,
        fn_typed_params,
        registry,
      )
    let effect_set =
      list.fold(all_effects, types.empty(), fn(combined, pair) {
        types.union(combined, pair.1)
      })
    // If the function's inferred effects reference effect variables
    // (because it calls fn-typed params), emit ParamBound entries so
    // the polymorphic annotation round-trips correctly.
    let inferred_params = polymorphic_param_bounds(effect_set, fn_typed_params)
    EffectAnnotation(
      kind: Effects,
      function: definition.definition.name,
      params: inferred_params,
      effects: effect_set,
    )
  })
}

/// Build ParamBound entries for each effect variable in `effect_set`
/// whose name is in `fn_typed_params`. The bound's effects are
/// `Polymorphic({}, {var_name})` — the variable refers to itself,
/// resolved later by substitution at call sites.
fn polymorphic_param_bounds(
  effect_set: EffectSet,
  fn_typed_params: Set(String),
) -> List(ParamBound) {
  case effect_set {
    Polymorphic(_, variables) ->
      variables
      |> set.to_list()
      |> list.filter(fn(v) { set.contains(fn_typed_params, v) })
      |> list.sort(string.compare)
      |> list.map(fn(v) {
        ParamBound(name: v, effects: Polymorphic(set.new(), set.from_list([v])))
      })
    _ -> []
  }
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
  registry: SignatureRegistry,
) -> #(List(Violation), List(Warning)) {
  case dict.get(function_map, annotation.function) {
    // Silently skip: the annotation may be stale or apply to a different
    // build target. Missing functions are not an error.
    Error(Nil) -> #([], [])
    Ok(function_definition) -> {
      let body_effects =
        collect_effects(
          function_definition.definition,
          function_map,
          context,
          knowledge_base,
          set.new(),
          annotation.params,
          set.new(),
          registry,
        )
      // A call is a violation when its effect set is not a subset of the
      // declared budget — i.e. it performs effects the caller didn't allow.
      let violations =
        body_effects
        |> list.filter(fn(pair) {
          let #(_, call_effects) = pair
          !types.is_subset(call_effects, annotation.effects)
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

      // Warn about function references passed as values with known non-pure effects.
      let extract_result =
        extract.extract_calls(function_definition.definition.body, context)
      let warnings =
        collect_reference_warnings(
          annotation.function,
          extract_result.references,
          knowledge_base,
        )

      #(violations, warnings)
    }
  }
}

fn collect_reference_warnings(
  function_name: String,
  references: List(types.ResolvedCall),
  knowledge_base: KnowledgeBase,
) -> List(Warning) {
  list.filter_map(references, fn(ref) {
    case effects.lookup(knowledge_base, ref.name) {
      effects.Known(effect_set) ->
        case effect_set == types.empty() {
          True -> Error(Nil)
          False ->
            Ok(UntrackedEffectWarning(
              function: function_name,
              reference: ref.name,
              span: ref.span,
              effects: effect_set,
            ))
        }
      effects.Unknown -> Error(Nil)
    }
  })
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
  fn_typed_params: Set(String),
  registry: SignatureRegistry,
) -> List(#(types.ResolvedCall, EffectSet)) {
  let result = extract.extract_calls(function.body, context)

  // Resolved calls: qualified names looked up directly in the knowledge
  // base. If the callee's effects are polymorphic (contain effect
  // variables), bind the variables by matching arguments at fn-typed
  // parameter positions and substitute for concrete effects.
  let resolved_effects =
    list.map(result.resolved, fn(call) {
      let effect_set = effects.lookup_effects(knowledge_base, call.name)
      let concrete =
        substitute_at_call_site(
          call,
          effect_set,
          result.call_args,
          knowledge_base,
          param_bounds,
          registry,
        )
      #(call, concrete)
    })

  // Local calls: check param bounds first (user-declared higher-order
  // constraints), then auto-detect fn-typed parameters and emit an
  // effect variable, then fall back to transitive analysis of local
  // definitions.
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
          case set.contains(fn_typed_params, local_call.function) {
            True -> {
              let synthetic_call =
                types.ResolvedCall(
                  name: QualifiedName(
                    module: "<param>",
                    function: local_call.function,
                  ),
                  span: local_call.span,
                )
              [
                #(
                  synthetic_call,
                  Polymorphic(set.new(), set.from_list([local_call.function])),
                ),
              ]
            }
            False ->
              resolve_unknown_local(
                local_call,
                visited,
                function_map,
                context,
                knowledge_base,
                registry,
              )
          }
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

/// Resolve effect variables at a call site. If the callee's effects
/// carry variables, match arguments to the callee's param bounds and
/// bind each variable to the concrete effect set of the corresponding
/// argument. `caller_param_bounds` lets us propagate effect bounds
/// from the caller's own parameters (when a fn-typed arg is itself
/// the caller's parameter).
fn substitute_at_call_site(
  call: types.ResolvedCall,
  effect_set: EffectSet,
  call_args: dict.Dict(Int, List(types.CallArgument)),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
) -> EffectSet {
  use <- bool.guard(when: !types.has_variables(effect_set), return: effect_set)
  let callee_bounds = effects.lookup_param_bounds(knowledge_base, call.name)
  let args = dict.get(call_args, call.span.start) |> result.unwrap([])
  let bindings =
    bind_variables(
      call.name,
      callee_bounds,
      args,
      knowledge_base,
      caller_param_bounds,
      registry,
    )
  types.substitute(effect_set, bindings)
}

/// Match arguments against a callee's param bounds and produce a
/// variable-to-effect-set binding map. For each param bound, find the
/// argument at its label (preferred) or position, and resolve the
/// argument's effects.
fn bind_variables(
  callee_name: types.QualifiedName,
  callee_bounds: List(ParamBound),
  args: List(types.CallArgument),
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
  registry: SignatureRegistry,
) -> dict.Dict(String, EffectSet) {
  list.fold(callee_bounds, dict.new(), fn(acc, bound) {
    // Find the argument matching this parameter: first by label,
    // then by real parameter position (via the signature registry),
    // and finally by the bound's index within the bounds list as a
    // last-resort fallback for callees we have no registry entry for.
    let matched =
      find_matching_arg(callee_name, bound, callee_bounds, args, registry)
    case matched {
      Some(arg) -> {
        let arg_effects =
          resolve_argument_effects(arg, knowledge_base, caller_param_bounds)
        // Extract the variable name(s) from this bound — typically the
        // bound was `param: [var_name]`, so `var_name` == bound.name.
        let var_names = variables_in(bound.effects)
        list.fold(var_names, acc, fn(d, var) {
          dict.insert(d, var, arg_effects)
        })
      }
      None -> acc
    }
  })
}

fn variables_in(effect_set: EffectSet) -> List(String) {
  case effect_set {
    Polymorphic(_, variables) -> set.to_list(variables)
    _ -> []
  }
}

/// Find the argument that matches a given param bound. Prefers label
/// match; falls back to positional match using the bound's index in
/// the bound list (which mirrors the parameter order).
fn find_matching_arg(
  callee_name: types.QualifiedName,
  bound: ParamBound,
  all_bounds: List(ParamBound),
  args: List(types.CallArgument),
  registry: SignatureRegistry,
) -> option.Option(types.CallArgument) {
  // Try three strategies in order:
  //   1. Label match (caller used an explicit argument label)
  //   2. Registry-backed position (authoritative when available)
  //   3. Fall back to the bound's index in the bounds list — only
  //      correct when every parameter has a bound, but preserves
  //      pre-registry behavior for dep callees.
  let by_label = find_arg_by_label(args, bound.name)
  use <- option.lazy_or(by_label)
  let by_position =
    position_from_registry(callee_name, bound.name, registry)
    |> option.then(fn(pos) { find_arg_at_position(args, pos) })
  use <- option.lazy_or(by_position)
  find_bound_index(bound, all_bounds, 0)
  |> option.then(fn(i) { find_arg_at_position(args, i) })
}

fn find_arg_by_label(
  args: List(types.CallArgument),
  label: String,
) -> option.Option(types.CallArgument) {
  list.find(args, fn(arg) { arg.label == Some(label) })
  |> option.from_result
}

fn find_arg_at_position(
  args: List(types.CallArgument),
  position: Int,
) -> option.Option(types.CallArgument) {
  list.find(args, fn(arg) { arg.position == position && arg.label == None })
  |> option.from_result
}

/// Look up the real parameter position of a named parameter in the
/// callee's signature. Returns `None` when the callee is not in the
/// registry or the parameter name doesn't match any labeled parameter.
fn position_from_registry(
  callee_name: types.QualifiedName,
  param_name: String,
  registry: SignatureRegistry,
) -> option.Option(Int) {
  // Try in-body parameter name first (auto-inferred bounds key off
  // the name, not the Gleam argument label). Fall back to label
  // matching for JSON-sourced signatures where name info isn't
  // available.
  use params <- option.then(signatures.lookup(registry, callee_name))
  let by_name =
    find_param_position(params, fn(p) { p.name == Some(param_name) })
  use <- option.lazy_or(by_name)
  find_param_position(params, fn(p) { p.label == Some(param_name) })
}

fn find_param_position(
  params: List(signatures.ParameterInfo),
  predicate: fn(signatures.ParameterInfo) -> Bool,
) -> option.Option(Int) {
  list.find(params, predicate)
  |> result.map(fn(p) { p.position })
  |> option.from_result
}

fn find_bound_index(
  target: ParamBound,
  bounds: List(ParamBound),
  acc: Int,
) -> option.Option(Int) {
  case bounds {
    [] -> None
    [first, ..rest] ->
      case first.name == target.name {
        True -> Some(acc)
        False -> find_bound_index(target, rest, acc + 1)
      }
  }
}

/// Look up the effects of an argument value. Function references →
/// KB lookup; constructors → pure; local refs matching a caller's
/// param bound → that bound's effects; otherwise [Unknown].
fn resolve_argument_effects(
  arg: types.CallArgument,
  knowledge_base: KnowledgeBase,
  caller_param_bounds: List(ParamBound),
) -> EffectSet {
  case arg.value {
    types.FunctionRef(name) -> effects.lookup_effects(knowledge_base, name)
    types.ConstructorRef -> types.empty()
    types.LocalRef(name) ->
      case list.find(caller_param_bounds, fn(b) { b.name == name }) {
        Ok(bound) -> bound.effects
        Error(Nil) -> types.from_labels(["Unknown"])
      }
    types.OtherExpression -> types.from_labels(["Unknown"])
  }
}

fn resolve_unknown_local(
  local_call: LocalCall,
  visited: Set(String),
  function_map: dict.Dict(String, Definition(Function)),
  context: ImportContext,
  knowledge_base: KnowledgeBase,
  registry: SignatureRegistry,
) -> List(#(ResolvedCall, EffectSet)) {
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
          [#(synthetic_call, types.from_labels(["Unknown"]))]
        }
        Ok(local_definition) -> {
          let new_visited = set.insert(visited, local_call.function)
          // Auto-detect fn-typed params for the local callee so its
          // body can produce effect variables too (nested higher-order
          // calls stay polymorphic through the transitive analysis).
          let nested_fn_typed =
            signatures.fn_typed_params_from_function(
              local_definition.definition,
            )
          collect_effects(
            local_definition.definition,
            function_map,
            context,
            knowledge_base,
            new_visited,
            [],
            nested_fn_typed,
            registry,
          )
        }
      }
  }
}

fn resolve_field_call(
  field_call: types.FieldCall,
  function: Function,
  knowledge_base: KnowledgeBase,
) -> EffectSet {
  let unknown = types.from_labels(["Unknown"])
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
