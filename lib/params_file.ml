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
        not (List.Assoc.mem base_fields name ~equal:String.equal))
    with
    | [] -> Ok ()
    | unknown ->
      Or_error.error_s
        [%message "unknown parameters" ~_:(List.map unknown ~f:fst : string list)]
  in
  let merged =
    List.map base_fields ~f:(fun (name, value) ->
      let value =
        Option.value (List.Assoc.find overrides name ~equal:String.equal) ~default:value
      in
      Sexp.List [ Atom name; value ])
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
