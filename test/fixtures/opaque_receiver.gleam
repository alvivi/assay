import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

fn make() -> Validator {
  Validator(to_error: io.println)
}

pub fn run() {
  // `v` is bound from a function call, so the syntax-level path sees it as
  // opaque. girard types it as `Validator`, so the `type` annotation in
  // fixtures.graded resolves the field call's effect to [Stdout].
  let v = make()
  v.to_error("oops")
}
