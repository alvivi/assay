//// Topological sort over a string-keyed dependency graph. Used by inference
//// to walk project (and path-dep) modules in dependency order so each module
//// is analysed after every other module it imports.
////
//// The graph is `Dict(node, Set(node it depends on))`. The output is a
//// leaves-first list: any node `u` that depends on `v` appears *after* `v`.
//// Gleam's no-circular-imports guarantee makes the import graph a DAG in
//// practice, but the algorithm still detects cycles defensively and returns
//// an `Error(cyclic_nodes)` instead of producing a partial order.

import gleam/dict.{type Dict}
import gleam/list
import gleam/set.{type Set}

/// Kahn's algorithm: produce a leaves-first ordering of `graph`. On success,
/// returns the sorted node list. On a cycle, returns the set of nodes still
/// participating in unresolved dependencies — useful for diagnostics.
pub fn sort(
  graph: Dict(String, Set(String)),
) -> Result(List(String), List(String)) {
  let in_degrees = dict.map_values(graph, fn(_node, deps) { set.size(deps) })
  let reverse = build_reverse_graph(graph)
  let initial_queue =
    in_degrees
    |> dict.filter(fn(_node, degree) { degree == 0 })
    |> dict.keys()
  kahn_loop(initial_queue, in_degrees, reverse, [])
}

fn kahn_loop(
  queue: List(String),
  in_degrees: Dict(String, Int),
  reverse: Dict(String, Set(String)),
  acc: List(String),
) -> Result(List(String), List(String)) {
  case queue {
    [] -> {
      let remaining = dict.filter(in_degrees, fn(_node, degree) { degree > 0 })
      case dict.is_empty(remaining) {
        True -> Ok(list.reverse(acc))
        False -> Error(dict.keys(remaining))
      }
    }
    [node, ..rest] -> {
      let dependents = case dict.get(reverse, node) {
        Ok(s) -> set.to_list(s)
        Error(_) -> []
      }
      let #(new_in_degrees, newly_zero) =
        list.fold(dependents, #(in_degrees, []), fn(state, dependent) {
          let #(degrees, zero_acc) = state
          let current = case dict.get(degrees, dependent) {
            Ok(d) -> d
            Error(_) -> 0
          }
          let updated = current - 1
          let new_degrees = dict.insert(degrees, dependent, updated)
          case updated {
            0 -> #(new_degrees, [dependent, ..zero_acc])
            _ -> #(new_degrees, zero_acc)
          }
        })
      kahn_loop(list.append(rest, newly_zero), new_in_degrees, reverse, [
        node,
        ..acc
      ])
    }
  }
}

/// Invert a forward dependency graph (`node -> deps of node`) into a
/// dependents graph (`node -> things that depend on node`). Used by Kahn's
/// algorithm to find which nodes become unblocked when a leaf is processed.
fn build_reverse_graph(
  graph: Dict(String, Set(String)),
) -> Dict(String, Set(String)) {
  dict.fold(graph, dict.new(), fn(reverse, node, deps) {
    set.fold(deps, reverse, fn(rev, dep) {
      let existing = case dict.get(rev, dep) {
        Ok(s) -> s
        Error(_) -> set.new()
      }
      dict.insert(rev, dep, set.insert(existing, node))
    })
  })
}
