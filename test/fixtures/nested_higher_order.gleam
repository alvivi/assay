import gleam/io
import gleam/list

pub fn apply_twice(f: fn(Int) -> Int, x: Int) -> List(Int) {
  list.map([x], f)
}

pub fn outer(f: fn(Int) -> Int, x: Int) -> List(Int) {
  middle(f, x)
}

fn middle(g: fn(Int) -> Int, x: Int) -> List(Int) {
  inner(g, x)
}

fn inner(h: fn(Int) -> Int, x: Int) -> List(Int) {
  list.map([x], h)
}

pub fn log_and_map(f: fn(Int) -> Int, x: Int) -> List(Int) {
  io.println("mapping")
  list.map([x], f)
}

pub fn pure_forward(f: fn(Int) -> Int, items: List(Int)) -> List(Int) {
  list.map(items, f)
}
