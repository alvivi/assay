import filepath
import glance.{
  type Clause, type Expression, type Field, type Module, type Statement,
}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import graded/internal/types.{
  type ArgumentValue, type CallArgument, type FieldCall, type LocalBinding,
  type LocalCall, type QualifiedName, type ResolvedCall, BoundAlias,
  BoundConstructor, BoundFunctionRef, BoundOpaque, CallArgument, ConstructorRef,
  FieldCall, FunctionRef, LocalCall, LocalRef, OtherExpression, QualifiedName,
  ResolvedCall,
}

/// Binding environment: local names introduced by `let` bindings inside
/// a function body, mapped to their classification. Threaded through
/// statement walks so subsequent statements see earlier bindings. Block
/// and `fn(...)` bodies inherit the outer env but their own bindings do
/// not leak back out.
pub type Env =
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
pub type ImportContext {
  ImportContext(
    aliases: Dict(String, String),
    unqualified: Dict(String, QualifiedName),
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

  ImportContext(aliases:, unqualified:)
}

/// Extract all calls from a list of statements.
///
/// Public entry: starts with an empty binding env and discards the
/// final env. Internally `walk_statements` threads env through so
/// assignments can be resolved by later statements.
pub fn extract_calls(
  statements: List(Statement),
  context: ImportContext,
) -> ExtractResult {
  let #(result, _env) = walk_statements(statements, context, dict.new())
  result
}

fn walk_statements(
  statements: List(Statement),
  context: ImportContext,
  env: Env,
) -> #(ExtractResult, Env) {
  list.fold(statements, #(empty(), env), fn(state, statement) {
    let #(accumulated, current_env) = state
    let #(result, next_env) =
      extract_from_statement(statement, context, current_env)
    #(merge(accumulated, result), next_env)
  })
}

/// Walk a child scope (block or fn body): inherits the outer env but
/// discards its own bindings on exit so they don't leak out.
fn walk_child_scope(
  statements: List(Statement),
  context: ImportContext,
  env: Env,
) -> ExtractResult {
  let #(result, _env) = walk_statements(statements, context, env)
  result
}

// PRIVATE

fn is_constructor_name(name: String) -> Bool {
  case string.first(name) {
    Ok(char) -> char == string.uppercase(char) && char != string.lowercase(char)
    Error(Nil) -> False
  }
}

/// Resolve a bare-name call, consulting the local binding env first.
/// If the name was introduced by a `let` that captured a function
/// reference, the call becomes a ResolvedCall; otherwise fall through
/// to the import-based resolution.
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

/// Resolve a qualified `alias.label` call or pipe target. Constructor
/// labels short-circuit to empty (pure value creation). Import aliases
/// produce a cross-module ResolvedCall. If `alias` is a local binding
/// (a record constructed in this function), look up the field in the
/// binding env and resolve based on the field's value. Otherwise fall
/// back to a FieldCall.
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
        BoundConstructor(fields:, ..) ->
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

/// Resolve a labelled field of a locally-constructed record to a call.
/// If the stored value is a function reference or a local name, emit a
/// resolved or local call; otherwise fall back to a FieldCall so the
/// type-level `type Foo.field : [...]` annotation path still applies.
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
/// `classify_rhs`. Destructuring patterns (`let #(a, b) = ...`,
/// `let Validator(..) = ...`) always bind their names to `BoundOpaque`
/// — tracking values through destructuring is out of scope.
fn bind_assignment(
  pattern: glance.Pattern,
  value: glance.Expression,
  context: ImportContext,
  env: Env,
) -> Env {
  case pattern {
    glance.PatternVariable(name:, ..) ->
      dict.insert(env, name, classify_rhs(value, context, env))
    _ ->
      list.fold(pattern_bound_names(pattern), env, fn(acc, name) {
        dict.insert(acc, name, BoundOpaque)
      })
  }
}

/// Classify the right-hand side of a simple `let name = rhs`. Anything
/// not recognised becomes `BoundOpaque`, which deliberately shadows
/// any earlier binding of the same name.
fn classify_rhs(
  expression: glance.Expression,
  context: ImportContext,
  env: Env,
) -> LocalBinding {
  case expression {
    glance.FieldAccess(
      container: glance.Variable(_, alias),
      label: function_name,
      ..,
    ) ->
      case is_constructor_name(function_name) {
        True -> BoundOpaque
        False ->
          case dict.get(context.aliases, alias) {
            Ok(module_path) ->
              BoundFunctionRef(name: QualifiedName(module_path, function_name))
            Error(Nil) -> BoundOpaque
          }
      }
    glance.Variable(_, name) ->
      case is_constructor_name(name) {
        True -> BoundOpaque
        False ->
          case dict.get(context.unqualified, name) {
            Ok(qualified_name) -> BoundFunctionRef(name: qualified_name)
            Error(Nil) ->
              case dict.has_key(env, name) {
                True -> BoundAlias(name:)
                False -> BoundOpaque
              }
          }
      }
    // Bare-constructor call: `Validator(to_error: MyError)`.
    glance.Call(function: glance.Variable(_, name), arguments:, ..) ->
      case is_constructor_name(name) {
        True ->
          classify_constructor(
            type_name: name,
            module: None,
            arguments: arguments,
            context: context,
            env: env,
          )
        False -> BoundOpaque
      }
    // Qualified-constructor call: `other.Validator(to_error: MyError)`.
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
        True ->
          classify_constructor(
            type_name: ctor,
            module: dict.get(context.aliases, alias) |> option.from_result,
            arguments: arguments,
            context: context,
            env: env,
          )
        False -> BoundOpaque
      }
    _ -> BoundOpaque
  }
}

/// Build a BoundConstructor from a constructor call's arguments.
/// Labelled arguments populate `fields`; unlabelled ones go to
/// `positional` in source order. Shorthand (`Validator(to_error:)`)
/// records `OtherExpression` for the value.
fn classify_constructor(
  type_name type_name: String,
  module module: Option(String),
  arguments arguments: List(Field(Expression)),
  context context: ImportContext,
  env env: Env,
) -> LocalBinding {
  let #(fields, positional) =
    list.fold(arguments, #(dict.new(), []), fn(acc, field) {
      let #(fields_acc, positional_acc) = acc
      case field {
        glance.LabelledField(label:, item:, ..) -> #(
          dict.insert(
            fields_acc,
            label,
            classify_expression(item, context, env),
          ),
          positional_acc,
        )
        glance.ShorthandField(label:, ..) -> #(
          dict.insert(fields_acc, label, OtherExpression),
          positional_acc,
        )
        glance.UnlabelledField(item:) -> #(fields_acc, [
          classify_expression(item, context, env),
          ..positional_acc
        ])
      }
    })
  BoundConstructor(
    type_name: type_name,
    module: module,
    fields: fields,
    positional: list.reverse(positional),
  )
}

/// Chase a chain of `BoundAlias` bindings to their root. Returns the
/// resolved binding (or `BoundOpaque` if the chain breaks or cycles).
/// Capped at a small number of hops to guard against pathological
/// inputs.
fn resolve_env(name: String, env: Env) -> LocalBinding {
  resolve_env_loop(name, env, 16)
}

fn resolve_env_loop(name: String, env: Env, fuel: Int) -> LocalBinding {
  use <- bool.guard(when: fuel <= 0, return: BoundOpaque)
  case dict.get(env, name) {
    Error(Nil) -> BoundOpaque
    Ok(BoundAlias(name: next)) -> resolve_env_loop(next, env, fuel - 1)
    Ok(binding) -> binding
  }
}

/// Names introduced by a `use` expression (`use a, b <- cont`) are
/// opaque — the values come from the callback callsite which we can't
/// trace syntactically.
fn bind_use_patterns(patterns: List(glance.UsePattern), env: Env) -> Env {
  list.fold(patterns, env, fn(acc, use_pattern) {
    list.fold(pattern_bound_names(use_pattern.pattern), acc, fn(acc2, name) {
      dict.insert(acc2, name, BoundOpaque)
    })
  })
}

/// Collect every variable name a pattern introduces into scope.
/// Destructuring patterns contribute all nested variable names.
fn pattern_bound_names(pattern: glance.Pattern) -> List(String) {
  case pattern {
    glance.PatternVariable(name:, ..) -> [name]
    glance.PatternAssignment(pattern: inner, name:, ..) -> [
      name,
      ..pattern_bound_names(inner)
    ]
    glance.PatternTuple(elements:, ..) ->
      list.flat_map(elements, pattern_bound_names)
    glance.PatternList(elements:, tail:, ..) -> {
      let head_names = list.flat_map(elements, pattern_bound_names)
      case tail {
        Some(tail_pattern) ->
          list.append(head_names, pattern_bound_names(tail_pattern))
        None -> head_names
      }
    }
    glance.PatternVariant(arguments:, ..) ->
      list.flat_map(arguments, fn(field) {
        case field {
          glance.LabelledField(item:, ..) -> pattern_bound_names(item)
          glance.ShorthandField(label:, ..) -> [label]
          glance.UnlabelledField(item:) -> pattern_bound_names(item)
        }
      })
    glance.PatternConcatenate(prefix_name:, rest_name:, ..) -> {
      let prefix_names = case prefix_name {
        Some(glance.Named(n)) -> [n]
        _ -> []
      }
      let rest_names = case rest_name {
        glance.Named(n) -> [n]
        glance.Discarded(_) -> []
      }
      list.append(prefix_names, rest_names)
    }
    glance.PatternBitString(segments:, ..) ->
      list.flat_map(segments, fn(segment) { pattern_bound_names(segment.0) })
    glance.PatternInt(..)
    | glance.PatternFloat(..)
    | glance.PatternString(..)
    | glance.PatternDiscard(..) -> []
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
    glance.Fn(body: statements, ..) ->
      walk_child_scope(statements, context, env)

    // Block
    glance.Block(statements:, ..) -> walk_child_scope(statements, context, env)

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
