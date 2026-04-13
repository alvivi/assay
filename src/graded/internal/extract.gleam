import filepath
import glance.{
  type Clause, type Expression, type Field, type Module, type Statement,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import graded/internal/types.{
  type ArgumentValue, type CallArgument, type FieldCall, type LocalCall,
  type QualifiedName, type ResolvedCall, CallArgument, ConstructorRef, FieldCall,
  FunctionRef, LocalCall, LocalRef, OtherExpression, QualifiedName, ResolvedCall,
}

/// Classification of a `let`-bound name inside a function body so that
/// later calls through the name can be resolved. `BoundOpaque` covers
/// everything we can't statically track (closures, computed values,
/// destructuring) and is also written on shadowing to erase stale
/// bindings.
type LocalBinding {
  BoundFunctionRef(name: QualifiedName)
  BoundConstructor(fields: Dict(String, ArgumentValue))
  BoundOpaque
}

type Env =
  Dict(String, LocalBinding)

/// Compute the dotted module name (as it appears in `import` statements) for
/// a `.gleam` file under a given source directory. For example,
/// `module_path_for_source("src/app/router.gleam", "src")` returns
/// `"app/router"`. The returned string is what `build_import_context` will
/// produce for any module that imports this file — the project's dependency
/// graph is built by intersecting the two.
pub fn module_path_for_source(
  gleam_path: String,
  source_directory: String,
) -> String {
  let prefix = source_directory <> "/"
  let relative = case string.starts_with(gleam_path, prefix) {
    True -> string.drop_start(gleam_path, string.length(prefix))
    False -> gleam_path
  }
  filepath.strip_extension(relative)
}

/// Import context built from a module's import list.
///
/// `constructors` maps a same-module custom-type constructor name to
/// the ordered labels of its fields (`None` for unlabelled positions).
/// Used to route positional arguments (`Validator(x)`) to the right
/// field label when building a `BoundConstructor`.
pub type ImportContext {
  ImportContext(
    aliases: Dict(String, String),
    unqualified: Dict(String, QualifiedName),
    constructors: Dict(String, List(Option(String))),
  )
}

/// Result of extracting calls from a function body.
///
/// `call_args` maps a resolved call's span start (unique per AST node)
/// to the call's arguments. Only populated for resolved calls — local
/// and field calls don't need argument tracking for substitution yet.
pub type ExtractResult {
  ExtractResult(
    resolved: List(ResolvedCall),
    local: List(LocalCall),
    field: List(FieldCall),
    references: List(ResolvedCall),
    call_args: Dict(Int, List(CallArgument)),
  )
}

/// Build import context from a parsed module's imports.
pub fn build_import_context(module: Module) -> ImportContext {
  let #(aliases, unqualified) =
    list.fold(module.imports, #(dict.new(), dict.new()), fn(state, definition) {
      let import_ = definition.definition
      let module_path = import_.module

      let alias = case import_.alias {
        Some(glance.Named(name)) -> name
        Some(glance.Discarded(_)) -> last_segment(module_path)
        None -> last_segment(module_path)
      }

      let new_aliases = dict.insert(state.0, alias, module_path)

      let new_unqualified =
        list.fold(
          import_.unqualified_values,
          state.1,
          fn(unqualified_map, unqualified_import) {
            let name = case unqualified_import.alias {
              Some(alias_name) -> alias_name
              None -> unqualified_import.name
            }
            dict.insert(
              unqualified_map,
              name,
              QualifiedName(
                module: module_path,
                function: unqualified_import.name,
              ),
            )
          },
        )

      #(new_aliases, new_unqualified)
    })

  let constructors = build_constructor_registry(module)
  ImportContext(aliases:, unqualified:, constructors:)
}

fn build_constructor_registry(
  module: Module,
) -> Dict(String, List(Option(String))) {
  list.fold(module.custom_types, dict.new(), fn(acc, definition) {
    list.fold(definition.definition.variants, acc, fn(acc2, variant) {
      let labels =
        list.map(variant.fields, fn(field) {
          case field {
            glance.LabelledVariantField(label:, ..) -> Some(label)
            glance.UnlabelledVariantField(..) -> None
          }
        })
      dict.insert(acc2, variant.name, labels)
    })
  })
}

/// Extract all calls from a list of statements.
pub fn extract_calls(
  statements: List(Statement),
  context: ImportContext,
) -> ExtractResult {
  walk_scope(statements, context, dict.new())
}

/// Walk a sequence of statements threading the binding env forward so
/// later statements see earlier `let`s. The final env is discarded —
/// block/closure bindings don't leak back to the enclosing scope.
fn walk_scope(
  statements: List(Statement),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  list.fold(statements, #(empty(), env), fn(state, statement) {
    let #(accumulated, current_env) = state
    let #(result, next_env) =
      extract_from_statement(statement, context, current_env)
    #(merge(accumulated, result), next_env)
  }).0
}

// PRIVATE

fn is_constructor_name(name: String) -> Bool {
  case string.first(name) {
    Ok(char) -> char == string.uppercase(char) && char != string.lowercase(char)
    Error(Nil) -> False
  }
}

/// Env-captured function refs beat import-based resolution.
fn resolve_variable_call(
  name: String,
  span: glance.Span,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case resolve_env(name, env) {
    BoundFunctionRef(name: qualified) ->
      ExtractResult(
        resolved: [ResolvedCall(qualified, span)],
        local: [],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    _ -> resolve_unqualified_call(name, span, context)
  }
}

fn resolve_unqualified_call(
  name: String,
  span: glance.Span,
  context: ImportContext,
) -> ExtractResult {
  case is_constructor_name(name) {
    True -> empty()
    False ->
      case dict.get(context.unqualified, name) {
        Ok(qualified_name) ->
          ExtractResult(
            resolved: [ResolvedCall(qualified_name, span)],
            local: [],
            field: [],
            references: [],
            call_args: dict.new(),
          )
        Error(Nil) ->
          ExtractResult(
            resolved: [],
            local: [LocalCall(name, span)],
            field: [],
            references: [],
            call_args: dict.new(),
          )
      }
  }
}

/// `alias.label` where `alias` is either an imported module (cross-module
/// call), a locally-constructed record (field-call resolution via env),
/// or an unknown local (FieldCall for type-level annotation lookup).
fn resolve_qualified_call(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case is_constructor_name(function_name) {
    True -> empty()
    False -> qualified_call_lookup(alias, function_name, span, context, env)
  }
}

fn qualified_call_lookup(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case dict.get(context.aliases, alias) {
    Ok(module_path) ->
      ExtractResult(
        resolved: [
          ResolvedCall(QualifiedName(module_path, function_name), span),
        ],
        local: [],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    Error(Nil) ->
      case resolve_env(alias, env) {
        BoundConstructor(fields:) ->
          resolve_constructor_field_call(alias, function_name, span, fields)
        _ ->
          ExtractResult(
            resolved: [],
            local: [],
            field: [FieldCall(alias, function_name, span)],
            references: [],
            call_args: dict.new(),
          )
      }
  }
}

/// Fallback to `FieldCall` preserves the type-level
/// `type Foo.field : [...]` annotation path for unresolved cases.
fn resolve_constructor_field_call(
  alias: String,
  label: String,
  span: glance.Span,
  fields: Dict(String, ArgumentValue),
) -> ExtractResult {
  case dict.get(fields, label) {
    Ok(FunctionRef(name: qualified)) ->
      ExtractResult(
        resolved: [ResolvedCall(qualified, span)],
        local: [],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    Ok(LocalRef(name: local_name)) ->
      ExtractResult(
        resolved: [],
        local: [LocalCall(local_name, span)],
        field: [],
        references: [],
        call_args: dict.new(),
      )
    Ok(ConstructorRef) -> empty()
    Ok(OtherExpression) | Error(Nil) ->
      ExtractResult(
        resolved: [],
        local: [],
        field: [FieldCall(alias, label, span)],
        references: [],
        call_args: dict.new(),
      )
  }
}

/// Resolve a qualified `alias.label` used as a value (not called).
/// Constructors short-circuit to empty; unknown aliases are dropped.
fn resolve_qualified_reference(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
) -> ExtractResult {
  case is_constructor_name(function_name) {
    True -> empty()
    False -> qualified_reference_lookup(alias, function_name, span, context)
  }
}

fn qualified_reference_lookup(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
) -> ExtractResult {
  case dict.get(context.aliases, alias) {
    Ok(module_path) ->
      ExtractResult(
        resolved: [],
        local: [],
        field: [],
        references: [
          ResolvedCall(QualifiedName(module_path, function_name), span),
        ],
        call_args: dict.new(),
      )
    Error(Nil) -> empty()
  }
}

fn last_segment(module_path: String) -> String {
  module_path
  |> string.split("/")
  |> list.last()
  |> result.unwrap(module_path)
}

fn extract_from_statement(
  statement: Statement,
  context: ImportContext,
  env: Env,
) -> #(ExtractResult, Env) {
  case statement {
    glance.Expression(expression) -> #(
      extract_from_expression(expression, context, env),
      env,
    )
    glance.Assignment(pattern:, value: expression, ..) -> {
      let result = extract_from_expression(expression, context, env)
      let next_env = bind_assignment(pattern, expression, context, env)
      #(result, next_env)
    }
    glance.Use(patterns:, function: expression, ..) -> {
      let result = extract_from_expression(expression, context, env)
      let next_env = bind_use_patterns(patterns, env)
      #(result, next_env)
    }
    glance.Assert(expression:, message:, ..) -> {
      let expression_result = extract_from_expression(expression, context, env)
      let combined = case message {
        Some(message_expression) ->
          merge(
            expression_result,
            extract_from_expression(message_expression, context, env),
          )
        None -> expression_result
      }
      #(combined, env)
    }
  }
}

/// Record the names introduced by a `let` pattern.
///
/// A `PatternVariable` (simple `let x = rhs`) is classified via
/// Destructuring patterns always bind their names to `BoundOpaque` —
/// tracking values through destructuring is out of scope.
fn bind_assignment(
  pattern: glance.Pattern,
  value: glance.Expression,
  context: ImportContext,
  env: Env,
) -> Env {
  case pattern {
    glance.PatternVariable(name:, ..) ->
      dict.insert(env, name, classify_rhs(value, context, env))
    _ -> fold_pattern_names(pattern, env, bind_opaque)
  }
}

fn bind_opaque(env: Env, name: String) -> Env {
  dict.insert(env, name, BoundOpaque)
}

/// Classify the right-hand side of a `let name = rhs`. Unrecognised
/// shapes become `BoundOpaque`, which deliberately shadows any earlier
/// binding of the same name.
fn classify_rhs(
  expression: glance.Expression,
  context: ImportContext,
  env: Env,
) -> LocalBinding {
  case expression {
    glance.Call(function: glance.Variable(_, name), arguments:, ..) ->
      case is_constructor_name(name) {
        True -> classify_constructor(name, None, arguments, context, env)
        False -> classify_rhs_ref(expression, context, env)
      }
    glance.Call(
      function: glance.FieldAccess(
        container: glance.Variable(_, alias),
        label: ctor,
        ..,
      ),
      arguments:,
      ..,
    ) ->
      case is_constructor_name(ctor) {
        True -> {
          let module = dict.get(context.aliases, alias) |> option.from_result
          classify_constructor(ctor, module, arguments, context, env)
        }
        False -> BoundOpaque
      }
    _ -> classify_rhs_ref(expression, context, env)
  }
}

/// For RHS expressions that aren't constructor calls, reuse
/// `classify_expression`'s shape recognition and map its result to a
/// `LocalBinding`. Eager resolution through the env means aliases never
/// need to be chased at lookup time.
fn classify_rhs_ref(
  expression: glance.Expression,
  context: ImportContext,
  env: Env,
) -> LocalBinding {
  case classify_expression(expression, context, env) {
    FunctionRef(name:) -> BoundFunctionRef(name:)
    LocalRef(name:) -> dict.get(env, name) |> result.unwrap(BoundOpaque)
    ConstructorRef | OtherExpression -> BoundOpaque
  }
}

/// Build a BoundConstructor from a constructor call's arguments.
/// Labelled arguments populate `fields` directly. Unlabelled ones are
/// mapped to the corresponding labelled slot when the constructor's
/// declared labels are known (same-module); otherwise discarded —
/// field-call resolution only needs the labelled view.
fn classify_constructor(
  type_name: String,
  module: Option(String),
  arguments: List(Field(Expression)),
  context: ImportContext,
  env: Env,
) -> LocalBinding {
  let declared_labels = case module {
    None -> dict.get(context.constructors, type_name) |> result.unwrap([])
    Some(_) -> []
  }
  let #(fields, _remaining) =
    list.fold(arguments, #(dict.new(), declared_labels), fn(acc, field) {
      let #(fields_acc, remaining) = acc
      case field {
        glance.LabelledField(label:, item:, ..) -> #(
          dict.insert(
            fields_acc,
            label,
            classify_expression(item, context, env),
          ),
          remaining,
        )
        glance.ShorthandField(label:, ..) -> #(
          dict.insert(fields_acc, label, OtherExpression),
          remaining,
        )
        glance.UnlabelledField(item:) -> {
          let value = classify_expression(item, context, env)
          case remaining {
            [Some(label), ..rest] -> #(
              dict.insert(fields_acc, label, value),
              rest,
            )
            [_, ..rest] -> #(fields_acc, rest)
            [] -> #(fields_acc, [])
          }
        }
      }
    })
  BoundConstructor(fields:)
}

fn resolve_env(name: String, env: Env) -> LocalBinding {
  dict.get(env, name) |> result.unwrap(BoundOpaque)
}

/// `use` bindings come from the callback call-site, which we can't
/// trace syntactically — mark them all opaque.
fn bind_use_patterns(patterns: List(glance.UsePattern), env: Env) -> Env {
  list.fold(patterns, env, fn(acc, use_pattern) {
    fold_pattern_names(use_pattern.pattern, acc, bind_opaque)
  })
}

/// Walk a pattern and fold over every variable name it binds into
/// scope, avoiding the intermediate `List(String)` a collect-then-fold
/// would allocate.
fn fold_pattern_names(
  pattern: glance.Pattern,
  acc: a,
  step: fn(a, String) -> a,
) -> a {
  case pattern {
    glance.PatternVariable(name:, ..) -> step(acc, name)
    glance.PatternAssignment(pattern: inner, name:, ..) ->
      fold_pattern_names(inner, step(acc, name), step)
    glance.PatternTuple(elements:, ..) ->
      list.fold(elements, acc, fn(inner, p) {
        fold_pattern_names(p, inner, step)
      })
    glance.PatternList(elements:, tail:, ..) -> {
      let head =
        list.fold(elements, acc, fn(inner, p) {
          fold_pattern_names(p, inner, step)
        })
      case tail {
        Some(tail_pattern) -> fold_pattern_names(tail_pattern, head, step)
        None -> head
      }
    }
    glance.PatternVariant(arguments:, ..) ->
      list.fold(arguments, acc, fn(inner, field) {
        case field {
          glance.LabelledField(item:, ..) ->
            fold_pattern_names(item, inner, step)
          glance.ShorthandField(label:, ..) -> step(inner, label)
          glance.UnlabelledField(item:) -> fold_pattern_names(item, inner, step)
        }
      })
    glance.PatternConcatenate(prefix_name:, rest_name:, ..) -> {
      let with_prefix = case prefix_name {
        Some(glance.Named(n)) -> step(acc, n)
        _ -> acc
      }
      case rest_name {
        glance.Named(n) -> step(with_prefix, n)
        glance.Discarded(_) -> with_prefix
      }
    }
    glance.PatternBitString(segments:, ..) ->
      list.fold(segments, acc, fn(inner, segment) {
        fold_pattern_names(segment.0, inner, step)
      })
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> acc
  }
}

fn extract_from_expression(
  expression: Expression,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case expression {
    // Qualified call: io.println(x), or qualified type constructor: types.NotFound(id).
    // The argument walk is unconditional so side-effecting sub-expressions
    // inside a constructor's args (e.g. NotFound(io.println(x))) still propagate.
    glance.Call(
      location: span,
      function: glance.FieldAccess(
        container: glance.Variable(_, alias),
        label: function_name,
        ..,
      ),
      arguments:,
    ) ->
      merge_with_args(
        resolve_qualified_call(alias, function_name, span, context, env),
        extract_from_arguments(arguments, context, env),
        span,
        classify_arguments(arguments, context, env, 0),
      )

    // Unqualified or local call: println(x) or helper(x)
    glance.Call(location: span, function: glance.Variable(_, name), arguments:) ->
      merge_with_args(
        resolve_variable_call(name, span, context, env),
        extract_from_arguments(arguments, context, env),
        span,
        classify_arguments(arguments, context, env, 0),
      )

    // Other call shapes (e.g., result of another call being called)
    glance.Call(function: function_expression, arguments:, ..) ->
      merge(
        extract_from_expression(function_expression, context, env),
        extract_from_arguments(arguments, context, env),
      )

    // Pipe: left |> right. The piped value becomes implicit argument 0
    // of the right-hand call; explicit arguments shift up by one.
    glance.BinaryOperator(name: glance.Pipe, left:, right:, ..) -> {
      let pipe_arg =
        CallArgument(
          position: 0,
          label: None,
          value: classify_expression(left, context, env),
        )
      merge(
        extract_from_expression(left, context, env),
        extract_pipe_target(right, context, env, [pipe_arg]),
      )
    }

    // Other binary operators
    glance.BinaryOperator(left:, right:, ..) ->
      merge(
        extract_from_expression(left, context, env),
        extract_from_expression(right, context, env),
      )

    // Closure: effects in body contribute to enclosing function
    glance.Fn(body: statements, ..) -> walk_scope(statements, context, env)

    // Block
    glance.Block(statements:, ..) -> walk_scope(statements, context, env)

    // Case expression
    glance.Case(subjects:, clauses:, ..) ->
      merge(
        fold_expressions(subjects, context, env),
        list.fold(clauses, empty(), fn(accumulated, clause) {
          merge(accumulated, extract_from_clause(clause, context, env))
        }),
      )

    // Tuple
    glance.Tuple(elements:, ..) -> fold_expressions(elements, context, env)

    // List
    glance.List(elements:, rest:, ..) ->
      merge_optional(
        fold_expressions(elements, context, env),
        rest,
        context,
        env,
      )

    // Negate
    glance.NegateInt(value:, ..) -> extract_from_expression(value, context, env)
    glance.NegateBool(value:, ..) ->
      extract_from_expression(value, context, env)

    // Record update
    glance.RecordUpdate(record:, ..) ->
      extract_from_expression(record, context, env)

    // Function reference: qualified name used as a value (not called).
    glance.FieldAccess(
      location: span,
      container: glance.Variable(_, alias),
      label: function_name,
    ) -> resolve_qualified_reference(alias, function_name, span, context)

    // Other field access (not a call — just traversing)
    glance.FieldAccess(container:, ..) ->
      extract_from_expression(container, context, env)

    // Tuple index
    glance.TupleIndex(tuple:, ..) ->
      extract_from_expression(tuple, context, env)

    // FnCapture: function reference with partial application
    glance.FnCapture(
      function: function_expression,
      arguments_before:,
      arguments_after:,
      ..,
    ) ->
      merge(
        extract_from_expression(function_expression, context, env),
        merge(
          extract_from_arguments(arguments_before, context, env),
          extract_from_arguments(arguments_after, context, env),
        ),
      )

    // Echo
    glance.Echo(expression: Some(inner), ..) ->
      extract_from_expression(inner, context, env)
    glance.Echo(expression: None, ..) -> empty()

    // Unqualified function reference used as a value (not called)
    glance.Variable(location: span, name:) ->
      case dict.get(context.unqualified, name) {
        Ok(qualified_name) ->
          ExtractResult(
            resolved: [],
            local: [],
            field: [],
            references: [ResolvedCall(qualified_name, span)],
            call_args: dict.new(),
          )
        Error(Nil) -> empty()
      }

    // Leaf nodes
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Panic(..)
    | glance.Todo(..)
    | glance.BitString(..) -> empty()
  }
}

fn extract_pipe_target(
  expression: Expression,
  context: ImportContext,
  env: Env,
  pipe_args: List(CallArgument),
) -> ExtractResult {
  case expression {
    glance.FieldAccess(
      location: span,
      container: glance.Variable(_, alias),
      label: function_name,
    ) ->
      attach_pipe_args(
        resolve_qualified_call(alias, function_name, span, context, env),
        span,
        pipe_args,
      )

    glance.Variable(location: span, name:) ->
      attach_pipe_args(
        resolve_variable_call(name, span, context, env),
        span,
        pipe_args,
      )

    // `left |> right(args)` — the piped value is the first argument
    // and the explicit args shift up by one.
    glance.Call(
      location: span,
      function: glance.FieldAccess(
        container: glance.Variable(_, alias),
        label: function_name,
        ..,
      ),
      arguments:,
    ) ->
      merge_with_args(
        resolve_qualified_call(alias, function_name, span, context, env),
        extract_from_arguments(arguments, context, env),
        span,
        list.append(pipe_args, classify_arguments(arguments, context, env, 1)),
      )

    glance.Call(location: span, function: glance.Variable(_, name), arguments:) ->
      merge_with_args(
        resolve_variable_call(name, span, context, env),
        extract_from_arguments(arguments, context, env),
        span,
        list.append(pipe_args, classify_arguments(arguments, context, env, 1)),
      )

    // Any other shape — handle normally; no arg tracking.
    _ -> extract_from_expression(expression, context, env)
  }
}

fn extract_from_clause(
  clause: Clause,
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  let body_result = extract_from_expression(clause.body, context, env)
  case clause.guard {
    Some(guard) ->
      merge(body_result, extract_from_expression(guard, context, env))
    None -> body_result
  }
}

/// Build a CallArgument list from glance fields, starting at a given
/// position offset (used by pipes to leave position 0 for the piped value).
fn classify_arguments(
  arguments: List(Field(Expression)),
  context: ImportContext,
  env: Env,
  position_offset: Int,
) -> List(CallArgument) {
  list.index_map(arguments, fn(field, i) {
    let #(label, expression) = case field {
      glance.LabelledField(label:, item:, ..) -> #(Some(label), Some(item))
      glance.ShorthandField(label:, ..) -> #(Some(label), None)
      glance.UnlabelledField(item:) -> #(None, Some(item))
    }
    let value = case expression {
      None -> OtherExpression
      Some(expr) -> classify_expression(expr, context, env)
    }
    CallArgument(position: i + position_offset, label:, value:)
  })
}

/// Classify a single argument expression. Determines whether it's a
/// function reference (qualified or unqualified import), a local
/// identifier, a constructor (uppercase), or something else.
fn classify_expression(
  expression: Expression,
  context: ImportContext,
  env: Env,
) -> types.ArgumentValue {
  case expression {
    glance.FieldAccess(
      container: glance.Variable(_, alias),
      label: function_name,
      ..,
    ) ->
      case is_constructor_name(function_name) {
        True -> ConstructorRef
        False ->
          case dict.get(context.aliases, alias) {
            Ok(module_path) ->
              FunctionRef(name: QualifiedName(module_path, function_name))
            Error(Nil) -> OtherExpression
          }
      }
    glance.Variable(_, name) ->
      case is_constructor_name(name) {
        True -> ConstructorRef
        False ->
          case dict.get(context.unqualified, name) {
            Ok(qualified_name) -> FunctionRef(name: qualified_name)
            Error(Nil) ->
              case resolve_env(name, env) {
                BoundFunctionRef(name: qualified) ->
                  FunctionRef(name: qualified)
                _ -> LocalRef(name:)
              }
          }
      }
    _ -> OtherExpression
  }
}

/// Record a pipe target's argument list against its call span. Used
/// by the two pipe-target shapes (`|> foo.bar` and `|> bar`) that
/// don't go through `merge_with_args`.
fn attach_pipe_args(
  base: ExtractResult,
  span: glance.Span,
  pipe_args: List(CallArgument),
) -> ExtractResult {
  ExtractResult(
    ..base,
    call_args: dict.insert(base.call_args, span.start, pipe_args),
  )
}

/// Merge an extraction result with a call's sub-expression walk, and
/// record the call's argument list keyed by span start.
fn merge_with_args(
  call_result: ExtractResult,
  inner: ExtractResult,
  span: glance.Span,
  args: List(CallArgument),
) -> ExtractResult {
  let merged = merge(call_result, inner)
  ExtractResult(
    ..merged,
    call_args: dict.insert(merged.call_args, span.start, args),
  )
}

fn extract_from_arguments(
  arguments: List(Field(Expression)),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  list.fold(arguments, empty(), fn(accumulated, field) {
    let expression = case field {
      glance.LabelledField(item:, ..) -> Some(item)
      glance.ShorthandField(..) -> None
      glance.UnlabelledField(item:) -> Some(item)
    }
    case expression {
      Some(inner) ->
        merge(accumulated, extract_from_expression(inner, context, env))
      None -> accumulated
    }
  })
}

fn fold_expressions(
  expressions: List(Expression),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  list.fold(expressions, empty(), fn(accumulated, expression) {
    merge(accumulated, extract_from_expression(expression, context, env))
  })
}

fn merge_optional(
  base: ExtractResult,
  optional_expression: Option(Expression),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  case optional_expression {
    Some(expression) ->
      merge(base, extract_from_expression(expression, context, env))
    None -> base
  }
}

fn empty() -> ExtractResult {
  ExtractResult(
    resolved: [],
    local: [],
    field: [],
    references: [],
    call_args: dict.new(),
  )
}

fn merge(left: ExtractResult, right: ExtractResult) -> ExtractResult {
  ExtractResult(
    resolved: list.append(left.resolved, right.resolved),
    local: list.append(left.local, right.local),
    field: list.append(left.field, right.field),
    references: list.append(left.references, right.references),
    call_args: dict.merge(left.call_args, right.call_args),
  )
}
