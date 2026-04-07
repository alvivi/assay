import assay/internal/types.{
  type FieldCall, type LocalCall, type QualifiedName, type ResolvedCall,
  FieldCall, LocalCall, QualifiedName, ResolvedCall,
}
import glance.{
  type Clause, type Expression, type Field, type Module, type Statement,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Import context built from a module's import list.
pub type ImportContext {
  ImportContext(
    aliases: Dict(String, String),
    unqualified: Dict(String, QualifiedName),
  )
}

/// Result of extracting calls from a function body.
pub type ExtractResult {
  ExtractResult(
    resolved: List(ResolvedCall),
    local: List(LocalCall),
    field: List(FieldCall),
    references: List(ResolvedCall),
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
    // Qualified call: io.println(x)
    glance.Call(
      location: span,
      function: glance.FieldAccess(
        container: glance.Variable(_, alias),
        label: function_name,
        ..,
      ),
      arguments:,
    ) -> {
      let call_result = case dict.get(context.aliases, alias) {
        Ok(module_path) ->
          ExtractResult(
            resolved: [
              ResolvedCall(QualifiedName(module_path, function_name), span),
            ],
            local: [],
            field: [],
            references: [],
          )
        Error(Nil) ->
          ExtractResult(
            resolved: [],
            local: [],
            field: [
              FieldCall(alias, function_name, span),
            ],
            references: [],
          )
      }
      merge(call_result, extract_from_arguments(arguments, context))
    }

    // Unqualified or local call: println(x) or helper(x)
    glance.Call(location: span, function: glance.Variable(_, name), arguments:) -> {
      let call_result = case dict.get(context.unqualified, name) {
        Ok(qualified_name) ->
          ExtractResult(
            resolved: [ResolvedCall(qualified_name, span)],
            local: [],
            field: [],
            references: [],
          )
        Error(Nil) ->
          ExtractResult(
            resolved: [],
            local: [LocalCall(name, span)],
            field: [],
            references: [],
          )
      }
      merge(call_result, extract_from_arguments(arguments, context))
    }

    // Other call shapes (e.g., result of another call being called)
    glance.Call(function: function_expression, arguments:, ..) ->
      merge(
        extract_from_expression(function_expression, context),
        extract_from_arguments(arguments, context),
      )

    // Pipe: left |> right
    glance.BinaryOperator(name: glance.Pipe, left:, right:, ..) ->
      merge(
        extract_from_expression(left, context),
        extract_pipe_target(right, context),
      )

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

    // Function reference: qualified name used as a value (not called)
    glance.FieldAccess(
      location: span,
      container: glance.Variable(_, alias),
      label: function_name,
    ) ->
      case dict.get(context.aliases, alias) {
        Ok(module_path) ->
          ExtractResult(resolved: [], local: [], field: [], references: [
            ResolvedCall(QualifiedName(module_path, function_name), span),
          ])
        Error(Nil) -> empty()
      }

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
          ExtractResult(resolved: [], local: [], field: [], references: [
            ResolvedCall(qualified_name, span),
          ])
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
) -> ExtractResult {
  case expression {
    glance.FieldAccess(
      location: span,
      container: glance.Variable(_, alias),
      label: function_name,
    ) ->
      case dict.get(context.aliases, alias) {
        Ok(module_path) ->
          ExtractResult(
            resolved: [
              ResolvedCall(QualifiedName(module_path, function_name), span),
            ],
            local: [],
            field: [],
            references: [],
          )
        Error(Nil) ->
          ExtractResult(
            resolved: [],
            local: [],
            field: [
              FieldCall(alias, function_name, span),
            ],
            references: [],
          )
      }

    glance.Variable(location: span, name:) ->
      case dict.get(context.unqualified, name) {
        Ok(qualified_name) ->
          ExtractResult(
            resolved: [ResolvedCall(qualified_name, span)],
            local: [],
            field: [],
            references: [],
          )
        Error(Nil) ->
          ExtractResult(
            resolved: [],
            local: [LocalCall(name, span)],
            field: [],
            references: [],
          )
      }

    // Call with extra args or other expression — handle normally
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
  ExtractResult(resolved: [], local: [], field: [], references: [])
}

fn merge(left: ExtractResult, right: ExtractResult) -> ExtractResult {
  ExtractResult(
    resolved: list.append(left.resolved, right.resolved),
    local: list.append(left.local, right.local),
    field: list.append(left.field, right.field),
    references: list.append(left.references, right.references),
  )
}
