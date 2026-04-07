//// Effect checker for Gleam via sidecar `.graded` annotation files.
////
//// graded verifies that your Gleam functions respect their declared effect
//// budgets. Annotations live in `.graded` sidecar files alongside your source
//// — your Gleam code stays clean.
////
//// ## Usage
////
//// ```sh
//// gleam run -m graded check [directory]   # enforce check annotations (default)
//// gleam run -m graded infer [directory]   # infer and write effect annotations
//// gleam run -m graded format [directory]  # normalize .graded file formatting
//// ```
////
//// ## Programmatic API
////
//// Use `run` to check a directory and get back a list of `CheckResult` values,
//// each containing any violations found per file. Use `run_infer` to infer
//// effects and write `.graded` files.
////

import argv
import filepath
import glance
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder
import graded/internal/annotation
import graded/internal/checker
import graded/internal/effects.{type KnowledgeBase}
import graded/internal/types.{
  type CheckResult, type GradedFile, type QualifiedName, type Violation,
  type Warning, AnnotationLine, CheckResult, GradedFile, QualifiedName,
}
import simplifile
import stdin

/// Errors that can occur during checking, inference, or formatting.
pub type GradedError {
  /// Could not read the source directory.
  DirectoryReadError(path: String, cause: simplifile.FileError)
  /// Could not read a source or annotation file.
  FileReadError(path: String, cause: simplifile.FileError)
  /// Could not write an annotation file.
  FileWriteError(path: String, cause: simplifile.FileError)
  /// Could not create the output directory for annotation files.
  DirectoryCreateError(path: String, cause: simplifile.FileError)
  /// A `.gleam` source file could not be parsed.
  GleamParseError(path: String, cause: glance.Error)
  /// A `.graded` annotation file could not be parsed.
  GradedParseError(path: String, cause: annotation.ParseError)
  /// One or more `.graded` files are not formatted (returned by `run_format_check`).
  FormatCheckFailed(paths: List(String))
}

pub fn main() -> Nil {
  let arguments = argv.load().arguments
  case arguments {
    ["infer", ..rest] ->
      case run_infer(target_directory(rest)) {
        Ok(Nil) -> io.println("graded: inferred effects written")
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["format", "--stdin"] -> {
      let input = stdin.read_lines() |> yielder.to_list() |> string.join("")
      case annotation.parse_file(input) {
        Ok(file) -> io.print(annotation.format_sorted(file))
        Error(_) -> {
          io.println_error("graded: error: could not parse stdin")
          halt(1)
        }
      }
    }
    ["format", "--check", ..rest] ->
      case run_format_check(target_directory(rest)) {
        Ok(Nil) -> Nil
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["format", ..rest] ->
      case run_format(target_directory(rest)) {
        Ok(Nil) -> Nil
        Error(error) -> {
          io.println_error("graded: error: " <> format_error(error))
          halt(1)
        }
      }
    ["check", ..rest] -> run_check(target_directory(rest))
    _ -> run_check(target_directory(arguments))
  }
}

/// Run the checker on all .gleam files in a directory.
/// Only enforces `check` annotations.
pub fn run(directory: String) -> Result(List(CheckResult), GradedError) {
  let knowledge_base =
    effects.load_knowledge_base("build/packages")
    |> enrich_with_path_deps()
  use gleam_files <- result.try(find_gleam_files(directory))

  // Incremental adoption: files with no .graded sidecar are silently skipped,
  // not treated as errors. Files whose .graded fails to parse are also skipped
  // so a bad annotation in one file doesn't block checking the rest.
  let results =
    list.filter_map(gleam_files, fn(gleam_path) {
      let graded_path = gleam_to_graded_path(gleam_path, directory)
      case simplifile.read(graded_path) {
        Error(_no_graded_file) -> Error(Nil)
        Ok(graded_content) ->
          case check_file(gleam_path, graded_content, knowledge_base) {
            Ok(check_result) -> Ok(check_result)
            Error(_check_error) -> Error(Nil)
          }
      }
    })

  Ok(results)
}

/// Infer effects for all .gleam files and write/merge .graded files.
pub fn run_infer(directory: String) -> Result(Nil, GradedError) {
  let knowledge_base =
    effects.load_knowledge_base("build/packages")
    |> enrich_with_path_deps()
  use gleam_files <- result.try(find_gleam_files(directory))

  list.try_each(gleam_files, fn(gleam_path) {
    let graded_path = gleam_to_graded_path(gleam_path, directory)
    use module <- result.try(read_and_parse_gleam(gleam_path))

    let existing_file =
      simplifile.read(graded_path)
      |> result.map_error(fn(_) { Nil })
      |> result.try(fn(content) {
        annotation.parse_file(content) |> result.map_error(fn(_) { Nil })
      })

    let #(knowledge_base, existing_checks) = case existing_file {
      Ok(file) -> enrich_knowledge_base(file, knowledge_base)
      Error(Nil) -> #(knowledge_base, [])
    }

    let inferred = checker.infer(module, knowledge_base, existing_checks)

    let parent_directory = filepath.directory_name(graded_path)
    use Nil <- result.try(
      simplifile.create_directory_all(parent_directory)
      |> result.map_error(DirectoryCreateError(parent_directory, _)),
    )

    case inferred, existing_file {
      // Nothing inferred and no existing file — nothing to write.
      [], Error(Nil) -> Ok(Nil)
      // Existing file present — merge inferred effects, preserving comments,
      // blank lines, check annotations, and their ordering.
      _, Ok(file) -> {
        let merged = annotation.merge_inferred(file, inferred)
        write_graded_file(graded_path, merged)
      }
      // No existing file — create a fresh one from inferred effects.
      _, Error(Nil) -> {
        let graded_file = GradedFile(lines: list.map(inferred, AnnotationLine))
        write_graded_file(graded_path, graded_file)
      }
    }
  })
}

/// Format all .graded files in priv/graded/ for a given source directory.
pub fn run_format(directory: String) -> Result(Nil, GradedError) {
  use graded_files <- result.try(find_graded_files(directory))
  list.try_each(graded_files, fn(graded_path) {
    use formatted <- result.try(read_and_format(graded_path))
    simplifile.write(graded_path, formatted)
    |> result.map_error(FileWriteError(graded_path, _))
  })
}

/// Check that all .graded files are already formatted. Returns error with
/// the list of unformatted file paths. Exit code 1 in CI.
pub fn run_format_check(directory: String) -> Result(Nil, GradedError) {
  use graded_files <- result.try(find_graded_files(directory))
  let unformatted =
    list.filter_map(graded_files, fn(graded_path) {
      case read_and_format(graded_path) {
        Error(_) -> Error(Nil)
        Ok(formatted) ->
          case simplifile.read(graded_path) {
            Error(_) -> Error(Nil)
            Ok(content) ->
              case content == formatted {
                True -> Error(Nil)
                False -> Ok(graded_path)
              }
          }
      }
    })
  case unformatted {
    [] -> Ok(Nil)
    paths -> Error(FormatCheckFailed(paths:))
  }
}

/// Convert a .gleam source path to its .graded path in priv/graded/.
pub fn gleam_to_graded_path(
  gleam_path: String,
  source_directory: String,
) -> String {
  let prefix = source_directory <> "/"
  let relative = case string.starts_with(gleam_path, prefix) {
    True -> string.drop_start(gleam_path, string.length(prefix))
    False -> gleam_path
  }
  let graded_relative = filepath.strip_extension(relative) <> ".graded"
  let priv_directory = case source_directory {
    "src" -> "priv/graded"
    _ -> source_directory <> "/priv/graded"
  }
  priv_directory <> "/" <> graded_relative
}

// PRIVATE

fn enrich_with_path_deps(knowledge_base: KnowledgeBase) -> KnowledgeBase {
  let path_deps = effects.parse_path_dependencies("gleam.toml")
  case path_deps {
    [] -> knowledge_base
    _ -> {
      // Pass 1: infer with base KB, accumulating results across deps
      let pass1 = infer_all_path_deps(path_deps, knowledge_base)
      let enriched = effects.with_inferred(knowledge_base, pass1)
      // Pass 2: re-infer with enriched KB so cross-dep calls resolve
      let pass2 = infer_all_path_deps(path_deps, enriched)
      effects.with_inferred(knowledge_base, pass2)
    }
  }
}

fn infer_all_path_deps(
  path_deps: List(#(String, String)),
  base_kb: KnowledgeBase,
) -> dict.Dict(QualifiedName, types.EffectSet) {
  let result =
    list.fold(path_deps, #(dict.new(), base_kb), fn(state, dep) {
      let #(all_inferred, kb) = state
      let #(_name, dep_path) = dep
      let source_dir = dep_path <> "/src"
      let gleam_files = case simplifile.get_files(source_dir) {
        Ok(found) ->
          list.filter(found, fn(path) { string.ends_with(path, ".gleam") })
        Error(_) -> []
      }
      let dep_inferred =
        list.fold(gleam_files, dict.new(), fn(acc, gleam_path) {
          case parse_gleam_silent(gleam_path) {
            Error(Nil) -> acc
            Ok(module) -> {
              let module_path = source_relative_module(gleam_path, source_dir)
              let checks = load_path_dep_checks(dep_path, module_path)
              let annotations = checker.infer(module, kb, checks)
              list.fold(annotations, acc, fn(effect_acc, annotation) {
                dict.insert(
                  effect_acc,
                  QualifiedName(
                    module: module_path,
                    function: annotation.function,
                  ),
                  annotation.effects,
                )
              })
            }
          }
        })
      #(
        dict.merge(all_inferred, dep_inferred),
        effects.with_inferred(kb, dep_inferred),
      )
    })
  result.0
}

fn source_relative_module(gleam_path: String, source_dir: String) -> String {
  let prefix = source_dir <> "/"
  let relative = case string.starts_with(gleam_path, prefix) {
    True -> string.drop_start(gleam_path, string.length(prefix))
    False -> gleam_path
  }
  string.replace(relative, ".gleam", "")
}

fn load_path_dep_checks(
  dep_path: String,
  module_path: String,
) -> List(types.EffectAnnotation) {
  let graded_path = dep_path <> "/priv/graded/" <> module_path <> ".graded"
  case simplifile.read(graded_path) {
    Error(_) -> []
    Ok(content) ->
      case annotation.parse_file(content) {
        Error(_) -> []
        Ok(graded_file) -> annotation.extract_checks(graded_file)
      }
  }
}

fn parse_gleam_silent(path: String) -> Result(glance.Module, Nil) {
  use source <- result.try(
    simplifile.read(path) |> result.map_error(fn(_) { Nil }),
  )
  glance.module(source) |> result.map_error(fn(_) { Nil })
}

fn enrich_knowledge_base(
  graded_file: GradedFile,
  knowledge_base: KnowledgeBase,
) -> #(KnowledgeBase, List(types.EffectAnnotation)) {
  let checks = annotation.extract_checks(graded_file)
  let type_fields = annotation.extract_type_fields(graded_file)
  let externs = annotation.extract_externals(graded_file)
  let knowledge_base =
    effects.with_type_fields(knowledge_base, type_fields)
    |> effects.with_externals(externs)
  #(knowledge_base, checks)
}

fn find_graded_files(directory: String) -> Result(List(String), GradedError) {
  let priv_directory = case directory {
    "src" -> "priv/graded"
    _ -> directory <> "/priv/graded"
  }
  // A missing priv/graded/ directory is not an error — it just means
  // `graded infer` hasn't been run yet. Treat it as an empty file list.
  let files = case simplifile.get_files(priv_directory) {
    Ok(found) -> found
    Error(_) -> []
  }
  Ok(list.filter(files, fn(path) { string.ends_with(path, ".graded") }))
}

fn read_and_format(graded_path: String) -> Result(String, GradedError) {
  use content <- result.try(
    simplifile.read(graded_path)
    |> result.map_error(FileReadError(graded_path, _)),
  )
  use graded_file <- result.try(
    annotation.parse_file(content)
    |> result.map_error(GradedParseError(graded_path, _)),
  )
  Ok(annotation.format_sorted(graded_file))
}

fn target_directory(arguments: List(String)) -> String {
  case arguments {
    [directory, ..] -> directory
    [] -> "src"
  }
}

fn run_check(directory: String) -> Nil {
  case run(directory) {
    Ok(results) -> {
      let violations =
        list.flat_map(results, fn(check_result) { check_result.violations })
      let warnings =
        list.flat_map(results, fn(check_result) { check_result.warnings })
      list.each(results, print_warnings)
      case warnings {
        [] -> Nil
        _ ->
          io.println(
            "graded: " <> int.to_string(list.length(warnings)) <> " warning(s)",
          )
      }
      case violations {
        [] -> io.println("graded: all checks passed")
        _ -> {
          list.each(results, print_violations)
          io.println(
            "\ngraded: "
            <> int.to_string(list.length(violations))
            <> " violation(s) found",
          )
          halt(1)
        }
      }
    }
    Error(error) -> {
      io.println_error("graded: error: " <> format_error(error))
      halt(1)
    }
  }
}

fn find_gleam_files(directory: String) -> Result(List(String), GradedError) {
  simplifile.get_files(directory)
  |> result.map_error(DirectoryReadError(directory, _))
  |> result.map(list.filter(_, fn(path) { string.ends_with(path, ".gleam") }))
}

fn read_and_parse_gleam(
  gleam_path: String,
) -> Result(glance.Module, GradedError) {
  use source <- result.try(
    simplifile.read(gleam_path)
    |> result.map_error(FileReadError(gleam_path, _)),
  )
  glance.module(source)
  |> result.map_error(GleamParseError(gleam_path, _))
}

fn check_file(
  gleam_path: String,
  graded_content: String,
  knowledge_base: KnowledgeBase,
) -> Result(CheckResult, GradedError) {
  use graded_file <- result.try(
    annotation.parse_file(graded_content)
    |> result.map_error(GradedParseError(gleam_path, _)),
  )
  let #(knowledge_base, check_annotations) =
    enrich_knowledge_base(graded_file, knowledge_base)

  use module <- result.try(read_and_parse_gleam(gleam_path))

  let #(violations, warnings) =
    checker.check(module, check_annotations, knowledge_base)
  Ok(CheckResult(file: gleam_path, violations:, warnings:))
}

fn write_graded_file(
  path: String,
  graded_file: GradedFile,
) -> Result(Nil, GradedError) {
  simplifile.write(path, annotation.format_file(graded_file))
  |> result.map_error(FileWriteError(path, _))
}

fn format_error(error: GradedError) -> String {
  case error {
    DirectoryReadError(path, _) -> "Could not read directory: " <> path
    FileReadError(path, _) -> "Could not read: " <> path
    FileWriteError(path, _) -> "Could not write: " <> path
    DirectoryCreateError(path, _) -> "Could not create directory: " <> path
    GleamParseError(path, _) -> "Could not parse: " <> path
    GradedParseError(path, _) -> "Parse error in .graded file for: " <> path
    FormatCheckFailed(paths:) ->
      "Unformatted .graded files:\n"
      <> string.join(list.map(paths, fn(path) { "  " <> path }), "\n")
  }
}

fn print_violations(check_result: CheckResult) -> Nil {
  list.each(check_result.violations, fn(violation) {
    print_violation(check_result.file, violation)
  })
}

fn print_violation(file: String, violation: Violation) -> Nil {
  io.println(
    file
    <> ": "
    <> violation.function
    <> " calls "
    <> violation.call.module
    <> "."
    <> violation.call.function
    <> " with effects "
    <> effects.format_effect_set(violation.actual)
    <> " but declared "
    <> effects.format_effect_set(violation.declared),
  )
}

fn print_warnings(check_result: CheckResult) -> Nil {
  list.each(check_result.warnings, fn(warning) {
    print_warning(check_result.file, warning)
  })
}

fn print_warning(file: String, warning: Warning) -> Nil {
  io.println(
    file
    <> ": warning: "
    <> warning.function
    <> " passes "
    <> warning.reference.module
    <> "."
    <> warning.reference.function
    <> " as a value — its effects "
    <> effects.format_effect_set(warning.effects)
    <> " won't be tracked",
  )
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
