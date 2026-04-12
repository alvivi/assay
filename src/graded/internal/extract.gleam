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
  type CallArgument, type FieldCall, type LocalCall, type QualifiedName,
  type ResolvedCall, CallArgument, ConstructorRef, FieldCall, FunctionRef,
  LocalCall, LocalRef, OtherExpression, QualifiedName, ResolvedCall,
}

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
pub fn extract_calls(
  statements: List(Statement),
  context: ImportContext,
) -> ExtractResult {
  list.fold(statements, empty(), fn(accumulated, statement) {
    merge(accumulated, extract_from_statement(statement, context))
  })
}

// PRIVATE

fn is_constructor_name(name: String) -> Bool {
  case string.first(name) {
    Ok(char) -> char == string.uppercase(char) && char != string.lowercase(char)
    Error(Nil) -> False
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
/// labels short-circuit to empty (pure value creation). Known aliases
/// produce a cross-module ResolvedCall; unknown aliases fall back to a
/// FieldCall on a local variable.
fn resolve_qualified_call(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
) -> ExtractResult {
  case is_constructor_name(function_name) {
    True -> empty()
    False -> qualified_call_lookup(alias, function_name, span, context)
  }
}

fn qualified_call_lookup(
  alias: String,
  function_name: String,
  span: glance.Span,
  context: ImportContext,
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
      ExtractResult(
        resolved: [],
        local: [],
        field: [FieldCall(alias, function_name, span)],
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
) -> ExtractResult {
  case statement {
    glance.Expression(expression) ->
      extract_from_expression(expression, context)
    glance.Assignment(value: expression, ..) ->
      extract_from_expression(expression, context)
    glance.Use(function: expression, ..) ->
      extract_from_expression(expression, context)
    glance.Assert(expression:, message:, ..) -> {
      let expression_result = extract_from_expression(expression, context)
      case message {
        Some(message_expression) ->
          merge(
            expression_result,
            extract_from_expression(message_expression, context),
          )
        None -> expression_result
      }
    }
  }
}

fn extract_from_expression(
  expression: Expression,
  context: ImportContext,
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
        resolve_qualified_call(alias, function_name, span, context),
        extract_from_arguments(arguments, context),
        span,
        classify_arguments(arguments, context, 0),
      )

    // Unqualified or local call: println(x) or helper(x)
    glance.Call(location: span, function: glance.Variable(_, name), arguments:) ->
      merge_with_args(
        resolve_unqualified_call(name, span, context),
        extract_from_arguments(arguments, context),
        span,
        classify_arguments(arguments, context, 0),
      )

    // Other call shapes (e.g., result of another call being called)
    glance.Call(function: function_expression, arguments:, ..) ->
      merge(
        extract_from_expression(function_expression, context),
        extract_from_arguments(arguments, context),
      )

    // Pipe: left |> right. The piped value becomes implicit argument 0
    // of the right-hand call; explicit arguments shift up by one.
    glance.BinaryOperator(name: glance.Pipe, left:, right:, ..) -> {
      let pipe_arg =
        CallArgument(
          position: 0,
          label: None,
          value: classify_expression(left, context),
        )
      merge(
        extract_from_expression(left, context),
        extract_pipe_target(right, context, [pipe_arg]),
      )
    }

    // Other binary operators
    glance.BinaryOperator(left:, right:, ..) ->
      merge(
        extract_from_expression(left, context),
        extract_from_expression(right, context),
      )

    // Closure: effects in body contribute to enclosing function
    glance.Fn(body: statements, ..) -> extract_calls(statements, context)

    // Block
    glance.Block(statements:, ..) -> extract_calls(statements, context)

    // Case expression
    glance.Case(subjects:, clauses:, ..) ->
      merge(
        fold_expressions(subjects, context),
        list.fold(clauses, empty(), fn(accumulated, clause) {
          merge(accumulated, extract_from_clause(clause, context))
        }),
      )

    // Tuple
    glance.Tuple(elements:, ..) -> fold_expressions(elements, context)

    // List
    glance.List(elements:, rest:, ..) ->
      merge_optional(fold_expressions(elements, context), rest, context)

    // Negate
    glance.NegateInt(value:, ..) -> extract_from_expression(value, context)
    glance.NegateBool(value:, ..) -> extract_from_expression(value, context)

    // Record update
    glance.RecordUpdate(record:, ..) -> extract_from_expression(record, context)

    // Function reference: qualified name used as a value (not called).
    glance.FieldAccess(
      location: span,
      container: glance.Variable(_, alias),
      label: function_name,
    ) -> resolve_qualified_reference(alias, function_name, span, context)

    // Other field access (not a call — just traversing)
    glance.FieldAccess(container:, ..) ->
      extract_from_expression(container, context)

    // Tuple index
    glance.TupleIndex(tuple:, ..) -> extract_from_expression(tuple, context)

    // FnCapture: function reference with partial application
    glance.FnCapture(
      function: function_expression,
      arguments_before:,
      arguments_after:,
      ..,
    ) ->
      merge(
        extract_from_expression(function_expression, context),
        merge(
          extract_from_arguments(arguments_before, context),
          extract_from_arguments(arguments_after, context),
        ),
      )

    // Echo
    glance.Echo(expression: Some(inner), ..) ->
      extract_from_expression(inner, context)
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
  pipe_args: List(CallArgument),
) -> ExtractResult {
  case expression {
    glance.FieldAccess(
      location: span,
      container: glance.Variable(_, alias),
      label: function_name,
    ) ->
      attach_pipe_args(
        resolve_qualified_call(alias, function_name, span, context),
        span,
        pipe_args,
      )

    glance.Variable(location: span, name:) ->
      attach_pipe_args(
        resolve_unqualified_call(name, span, context),
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
        resolve_qualified_call(alias, function_name, span, context),
        extract_from_arguments(arguments, context),
        span,
        list.append(pipe_args, classify_arguments(arguments, context, 1)),
      )

    glance.Call(location: span, function: glance.Variable(_, name), arguments:) ->
      merge_with_args(
        resolve_unqualified_call(name, span, context),
        extract_from_arguments(arguments, context),
        span,
        list.append(pipe_args, classify_arguments(arguments, context, 1)),
      )

    // Any other shape — handle normally; no arg tracking.
    _ -> extract_from_expression(expression, context)
  }
}

fn extract_from_clause(clause: Clause, context: ImportContext) -> ExtractResult {
  let body_result = extract_from_expression(clause.body, context)
  case clause.guard {
    Some(guard) -> merge(body_result, extract_from_expression(guard, context))
    None -> body_result
  }
}

/// Build a CallArgument list from glance fields, starting at a given
/// position offset (used by pipes to leave position 0 for the piped value).
fn classify_arguments(
  arguments: List(Field(Expression)),
  context: ImportContext,
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
      Some(expr) -> classify_expression(expr, context)
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
            Error(Nil) -> LocalRef(name:)
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
) -> ExtractResult {
  list.fold(arguments, empty(), fn(accumulated, field) {
    let expression = case field {
      glance.LabelledField(item:, ..) -> Some(item)
      glance.ShorthandField(..) -> None
      glance.UnlabelledField(item:) -> Some(item)
    }
    case expression {
      Some(inner) -> merge(accumulated, extract_from_expression(inner, context))
      None -> accumulated
    }
  })
}

fn fold_expressions(
  expressions: List(Expression),
  context: ImportContext,
) -> ExtractResult {
  list.fold(expressions, empty(), fn(accumulated, expression) {
    merge(accumulated, extract_from_expression(expression, context))
  })
}

fn merge_optional(
  base: ExtractResult,
  optional_expression: Option(Expression),
  context: ImportContext,
) -> ExtractResult {
  case optional_expression {
    Some(expression) ->
      merge(base, extract_from_expression(expression, context))
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
