//// Property and unit tests for the topological sort algorithm in
//// `graded/internal/topo`. The algorithm is the foundation of single-pass
//// inference (project modules and path deps both rely on it), so its
//// invariants are worth pinning down independently of any inference fixture.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleeunit/should
import graded/internal/topo
import qcheck

// ----- generators -----

/// Generate a random DAG by name. Strategy: produce a list of N node names
/// (`n0`, `n1`, …, `n{N-1}`), then for each `n_i` randomly choose deps from
/// `n_0..n_{i-1}`. This guarantees acyclicity by construction — there can
/// never be an edge from a lower-numbered node to a higher-numbered one.
fn random_dag_gen() -> qcheck.Generator(Dict(String, Set(String))) {
  use size <- qcheck.bind(qcheck.bounded_int(0, 12))
  let nodes = node_names(size)
  build_dag_gen(nodes, dict.new())
}

fn node_names(count: Int) -> List(String) {
  node_names_loop(count, [])
}

fn node_names_loop(remaining: Int, acc: List(String)) -> List(String) {
  case remaining <= 0 {
    True -> acc
    False -> {
      let next = remaining - 1
      node_names_loop(next, ["n" <> int.to_string(next), ..acc])
    }
  }
}

fn build_dag_gen(
  remaining: List(String),
  acc: Dict(String, Set(String)),
) -> qcheck.Generator(Dict(String, Set(String))) {
  case remaining {
    [] -> qcheck.return(acc)
    [node, ..rest] -> {
      let earlier = dict.keys(acc)
      use deps <- qcheck.bind(deps_subset_gen(earlier))
      build_dag_gen(rest, dict.insert(acc, node, set.from_list(deps)))
    }
  }
}

/// For each candidate, flip a coin to decide whether it becomes a dependency.
fn deps_subset_gen(candidates: List(String)) -> qcheck.Generator(List(String)) {
  case candidates {
    [] -> qcheck.return([])
    [c, ..rest] -> {
      use include <- qcheck.bind(qcheck.bool())
      use tail <- qcheck.bind(deps_subset_gen(rest))
      case include {
        True -> qcheck.return([c, ..tail])
        False -> qcheck.return(tail)
      }
    }
  }
}

// ----- helpers -----

fn position(haystack: List(String), needle: String) -> Int {
  position_loop(haystack, needle, 0)
}

fn position_loop(haystack: List(String), needle: String, index: Int) -> Int {
  case haystack {
    [] -> -1
    [head, ..rest] ->
      case head == needle {
        True -> index
        False -> position_loop(rest, needle, index + 1)
      }
  }
}

// ----- properties -----

pub fn topo_sort_length_preservation_test() {
  use graph <- qcheck.given(random_dag_gen())
  let assert Ok(sorted) = topo.sort(graph)
  list.length(sorted) |> should.equal(dict.size(graph))
}

pub fn topo_sort_set_preservation_test() {
  use graph <- qcheck.given(random_dag_gen())
  let assert Ok(sorted) = topo.sort(graph)
  let sorted_set = set.from_list(sorted)
  let nodes_set = set.from_list(dict.keys(graph))
  sorted_set |> should.equal(nodes_set)
}

/// Defining property of topological order: for every edge `u -> v` (u
/// depends on v), v must appear *before* u in the leaves-first output.
pub fn topo_sort_order_respects_edges_test() {
  use graph <- qcheck.given(random_dag_gen())
  let assert Ok(sorted) = topo.sort(graph)
  dict.each(graph, fn(node, deps) {
    set.fold(deps, Nil, fn(_, dep) {
      let node_index = position(sorted, node)
      let dep_index = position(sorted, dep)
      // dep must come before node — i.e. its index must be smaller.
      { dep_index < node_index } |> should.be_true()
      Nil
    })
  })
}

// ----- unit tests -----

pub fn topo_sort_empty_graph_test() {
  topo.sort(dict.new()) |> should.equal(Ok([]))
}

pub fn topo_sort_single_node_test() {
  let graph = dict.from_list([#("solo", set.new())])
  topo.sort(graph) |> should.equal(Ok(["solo"]))
}

pub fn topo_sort_simple_chain_test() {
  // a -> b -> c (a depends on b, b depends on c)
  let graph =
    dict.from_list([
      #("a", set.from_list(["b"])),
      #("b", set.from_list(["c"])),
      #("c", set.new()),
    ])
  let assert Ok(sorted) = topo.sort(graph)
  // Leaves first: c, then b, then a.
  sorted |> should.equal(["c", "b", "a"])
}

/// Cycle detection is unreachable from real Gleam projects (the compiler
/// rejects circular imports), but the algorithm itself must still report it
/// rather than producing a partial order — this test exercises that path.
pub fn topo_sort_detects_simple_cycle_test() {
  // a -> b -> a (a depends on b, b depends on a)
  let graph =
    dict.from_list([
      #("a", set.from_list(["b"])),
      #("b", set.from_list(["a"])),
    ])
  case topo.sort(graph) {
    Error(topo.Cycle(nodes:)) -> {
      list.contains(nodes, "a") |> should.be_true()
      list.contains(nodes, "b") |> should.be_true()
    }
    Ok(_) -> should.fail()
  }
}

pub fn topo_sort_detects_three_node_cycle_test() {
  // a -> b -> c -> a
  let graph =
    dict.from_list([
      #("a", set.from_list(["b"])),
      #("b", set.from_list(["c"])),
      #("c", set.from_list(["a"])),
    ])
  case topo.sort(graph) {
    Error(topo.Cycle(nodes:)) -> list.length(nodes) |> should.equal(3)
    Ok(_) -> should.fail()
  }
}

pub fn topo_sort_partial_cycle_returns_only_cyclic_nodes_test() {
  // leaf is acyclic; a <-> b is a cycle. The error should only include
  // nodes still participating in unresolved deps after Kahn's runs out of
  // queue items — that's `a` and `b`, not `leaf`.
  let graph =
    dict.from_list([
      #("leaf", set.new()),
      #("a", set.from_list(["b"])),
      #("b", set.from_list(["a"])),
    ])
  case topo.sort(graph) {
    Error(topo.Cycle(nodes:)) -> {
      list.contains(nodes, "leaf") |> should.be_false()
      list.contains(nodes, "a") |> should.be_true()
      list.contains(nodes, "b") |> should.be_true()
    }
    Ok(_) -> should.fail()
  }
}
