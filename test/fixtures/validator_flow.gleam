import gleam/io

pub type Validator {
  Validator(to_error: fn(String) -> Nil)
}

pub fn run() {
  let v = Validator(to_error: io.println)
  v.to_error("oops")
}
