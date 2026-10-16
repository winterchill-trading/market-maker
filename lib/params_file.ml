open! Core
open Exchange_core

let fields_of sexp =
  match (sexp : Sexp.t) with
  | List fields ->
    Or_error.try_with (fun () ->
      List.map fields ~f:(function
        | List [ Atom name; value ] -> name, value
        | field -> raise_s [%message "expected (name value)" (field : Sexp.t)]))
  | Atom _ ->
    Or_error.error_s [%message "expected a list of (name value) fields" (sexp : Sexp.t)]
;;

(* Every field name. [sexp_of_t] leaves out fields at their default
   ([action_rate_grace_ms]) or [None] ([action_rate_cooldown_ms], [toxicity_gate],
   [reference_guard]), so read the names off parameters where those are set. *)
let field_names =
  lazy
    (let probe =
       { Mm_core.Params.btc with
         action_rate_grace_ms =
           Time_ns.Span.(Mm_core.Params.btc.action_rate_grace_ms + millisecond)
       ; action_rate_cooldown_ms = Some Time_ns.Span.millisecond
       ; toxicity_gate = Some Mm_core.Toxicity_gate.Config.default
       ; reference_guard = Some Mm_core.Reference_guard.Config.default
       }
     in
     match Mm_core.Params.sexp_of_t probe with
     | List fields ->
       List.filter_map fields ~f:(function
         | List [ Atom name; _ ] -> Some name
         | _ -> None)
     | Atom _ -> [])
;;

(* Record-valued fields. A file may list only some of their fields: the others come from
   the base parameters' value, or from the default configuration when the base has none,
   so [(toxicity_gate ())] turns the gate on with its defaults. *)
let nested_defaults =
  [ ("toxicity_gate", Mm_core.Toxicity_gate.Config.(sexp_of_t default))
  ; ("reference_guard", Mm_core.Reference_guard.Config.(sexp_of_t default))
  ]
;;

(* As in the top-level durations, a [*_ms] field may be a plain integer of milliseconds;
   the nested configurations themselves only read spans. *)
let ms_span name (value : Sexp.t) : Sexp.t =
  match value with
  | Atom digits
    when String.is_suffix name ~suffix:"_ms"
         && (not (String.is_empty digits))
         && String.for_all digits ~f:Char.is_digit -> Atom (digits ^ "ms")
  | value -> value
;;

let merge_nested ~name ~base ~override =
  let open Or_error.Let_syntax in
  let%bind base = fields_of base in
  let%bind override = fields_of override |> Or_error.tag ~tag:name in
  let%map () =
    match
      List.filter override ~f:(fun (field, _) ->
        not (List.Assoc.mem base field ~equal:String.equal))
    with
    | [] -> Ok ()
    | unknown ->
      Or_error.error_s
        [%message
          "unknown parameters" ~in_:name ~_:(List.map unknown ~f:fst : string list)]
  in
  Sexp.List
    (List.map base ~f:(fun (field, value) ->
       let value =
         match List.Assoc.find override field ~equal:String.equal with
         | Some value -> ms_span field value
         | None -> value
       in
       Sexp.List [ Atom field; value ]))
;;

let apply (base : Mm_core.Params.t) ~overrides =
  let open Or_error.Let_syntax in
  let%bind overrides = fields_of overrides in
  let%bind base_fields = fields_of (Mm_core.Params.sexp_of_t base) in
  let%bind () =
    match
      List.find_a_dup overrides ~compare:(fun (a, _) (b, _) -> String.compare a b)
    with
    | Some (name, _) -> Or_error.error_s [%message "field set twice" name]
    | None -> Ok ()
  in
  let%bind () =
    match
      List.filter overrides ~f:(fun (name, _) ->
        not (List.mem (force field_names) name ~equal:String.equal))
    with
    | [] -> Ok ()
    | unknown ->
      Or_error.error_s
        [%message "unknown parameters" ~_:(List.map unknown ~f:fst : string list)]
  in
  let%bind overrides =
    List.map overrides ~f:(fun (name, value) ->
      match List.Assoc.find nested_defaults name ~equal:String.equal with
      | None -> Ok (name, value)
      | Some default ->
        let base =
          Option.value (List.Assoc.find base_fields name ~equal:String.equal) ~default
        in
        merge_nested ~name ~base ~override:value >>| fun value -> name, value)
    |> Or_error.combine_errors
  in
  let merged =
    List.map base_fields ~f:(fun (name, value) ->
      let value =
        Option.value (List.Assoc.find overrides name ~equal:String.equal) ~default:value
      in
      Sexp.List [ Atom name; value ])
    @ List.filter_map overrides ~f:(fun (name, value) ->
      Option.some_if
        (not (List.Assoc.mem base_fields name ~equal:String.equal))
        (Sexp.List [ Atom name; value ]))
  in
  let%bind params =
    Or_error.try_with (fun () -> Mm_core.Params.t_of_sexp (Sexp.List merged))
    |> Or_error.tag ~tag:"bad parameter value"
  in
  let%bind () =
    if Symbol.equal params.symbol base.symbol
    then Ok ()
    else
      Or_error.error_s
        [%message
          "the symbol cannot change"
            ~from:(base.symbol : Symbol.t)
            ~to_:(params.symbol : Symbol.t)]
  in
  Mm_core.Params.validate params
;;

let load path ~base =
  Or_error.try_with_join (fun () -> apply base ~overrides:(Sexp.load_sexp path))
  |> Or_error.tag ~tag:path
;;
