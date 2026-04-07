import assay/internal/types.{
  type EffectSet, AnnotationLine, AssayFile, BlankLine, Check, CommentLine,
  EffectAnnotation, Effects, ExternalAnnotation, ExternalLine, FunctionExternal,
  ModuleExternal, ParamBound, Specific, TypeFieldAnnotation, TypeFieldLine,
  Wildcard,
}
import gleam/dict
import gleam/list
import gleam/set
import qcheck

pub fn effect_set_gen() -> qcheck.Generator(EffectSet) {
  let label_gen =
    qcheck.from_generators(qcheck.return("Http"), [
      qcheck.return("Dom"),
      qcheck.return("Stdout"),
      qcheck.return("Db"),
      qcheck.return("FileSystem"),
      qcheck.return("Time"),
    ])
  let specific_gen =
    qcheck.map(qcheck.list_from(label_gen), fn(labels) {
      Specific(set.from_list(labels))
    })
  qcheck.from_weighted_generators(#(1, qcheck.return(Wildcard)), [
    #(4, specific_gen),
  ])
}

pub fn function_name_gen() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("foo"), [
    qcheck.return("bar"),
    qcheck.return("baz"),
    qcheck.return("run"),
    qcheck.return("handle"),
    qcheck.return("process"),
  ])
}

pub fn annotation_gen() -> qcheck.Generator(types.EffectAnnotation) {
  let kind_gen =
    qcheck.from_generators(qcheck.return(Effects), [qcheck.return(Check)])
  let param_name_gen =
    qcheck.from_generators(qcheck.return("f"), [
      qcheck.return("g"),
      qcheck.return("h"),
      qcheck.return("callback"),
      qcheck.return("handler"),
    ])
  let param_bound_gen =
    qcheck.map2(param_name_gen, effect_set_gen(), fn(name, effects) {
      ParamBound(name:, effects:)
    })
  let no_params =
    qcheck.map2(
      qcheck.map2(kind_gen, function_name_gen(), fn(k, f) { #(k, f) }),
      effect_set_gen(),
      fn(kf, effects) {
        let #(kind, function) = kf
        EffectAnnotation(kind:, function:, params: [], effects:)
      },
    )
  let with_param =
    qcheck.map2(
      qcheck.map2(kind_gen, function_name_gen(), fn(k, f) { #(k, f) }),
      qcheck.map2(param_bound_gen, effect_set_gen(), fn(p, e) { #(p, e) }),
      fn(kf, pe) {
        let #(kind, function) = kf
        let #(param, effects) = pe
        EffectAnnotation(kind:, function:, params: [param], effects:)
      },
    )
  qcheck.from_generators(no_params, [with_param])
}

pub fn type_field_gen() -> qcheck.Generator(types.TypeFieldAnnotation) {
  let type_name_gen =
    qcheck.from_generators(qcheck.return("Handler"), [
      qcheck.return("Request"),
      qcheck.return("Config"),
    ])
  let field_name_gen =
    qcheck.from_generators(qcheck.return("on_click"), [
      qcheck.return("send"),
      qcheck.return("validate"),
    ])
  qcheck.map2(
    qcheck.map2(type_name_gen, field_name_gen, fn(t, f) { #(t, f) }),
    effect_set_gen(),
    fn(tf, effects) {
      let #(type_name, field) = tf
      TypeFieldAnnotation(type_name:, field:, effects:)
    },
  )
}

pub fn external_gen() -> qcheck.Generator(types.ExternalAnnotation) {
  let module_name_gen =
    qcheck.from_generators(qcheck.return("gleam/io"), [
      qcheck.return("gleam/list"),
      qcheck.return("gleam/httpc"),
      qcheck.return("simplifile"),
    ])
  let module_ext =
    qcheck.map2(module_name_gen, effect_set_gen(), fn(module, effects) {
      ExternalAnnotation(module:, target: ModuleExternal, effects:)
    })
  let function_ext =
    qcheck.map2(
      qcheck.map2(module_name_gen, function_name_gen(), fn(m, f) { #(m, f) }),
      effect_set_gen(),
      fn(mf, effects) {
        let #(module, name) = mf
        ExternalAnnotation(module:, target: FunctionExternal(name), effects:)
      },
    )
  qcheck.from_generators(module_ext, [function_ext])
}

pub fn assay_file_gen() -> qcheck.Generator(types.AssayFile) {
  let comment_gen =
    qcheck.from_generators(qcheck.return("// TODO"), [
      qcheck.return("// Effect annotations"),
      qcheck.return("// Auto-generated"),
    ])
  let line_gen =
    qcheck.from_weighted_generators(
      #(3, qcheck.map(annotation_gen(), AnnotationLine)),
      [
        #(1, qcheck.map(type_field_gen(), TypeFieldLine)),
        #(1, qcheck.map(external_gen(), ExternalLine)),
        #(1, qcheck.map(comment_gen, CommentLine)),
        #(1, qcheck.return(BlankLine)),
      ],
    )
  qcheck.map2(line_gen, qcheck.list_from(line_gen), fn(first, rest) {
    AssayFile(lines: [first, ..rest])
  })
}

pub fn inferred_list_gen() -> qcheck.Generator(List(types.EffectAnnotation)) {
  let effects_ann_gen =
    qcheck.map2(function_name_gen(), effect_set_gen(), fn(function, effects) {
      EffectAnnotation(kind: Effects, function:, params: [], effects:)
    })
  qcheck.map(
    qcheck.map2(
      effects_ann_gen,
      qcheck.list_from(effects_ann_gen),
      fn(first, rest) { [first, ..rest] },
    ),
    fn(anns) {
      anns
      |> list.map(fn(a) { #(a.function, a) })
      |> dict.from_list()
      |> dict.values()
    },
  )
}
