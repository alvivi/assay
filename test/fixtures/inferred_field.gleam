import gleam/io

pub type Logger {
  Logger(emit: fn(String) -> Nil)
}

fn make() -> Logger {
  Logger(emit: io.println)
}

pub fn run() {
  // No `type Logger.emit` annotation exists. graded infers the field's effect
  // from the construction `Logger(emit: io.println)` (Stage C), and girard
  // types the receiver so the field call resolves to [Stdout].
  let l = make()
  l.emit("hi")
}
