open! Core
open! Async
open Market_maker

let base = Mm_core.Params.btc

let show overrides =
  match Params_file.apply base ~overrides:(Sexp.of_string overrides) with
  | Error error -> print_s [%message "rejected" ~_:(error : Error.t)]
  | Ok params ->
    (* Only the fields that differ from [base]. *)
    let fields p =
      match Mm_core.Params.sexp_of_t p with
      | List fields -> fields
      | Atom _ -> []
    in
    let changed =
      List.filter (fields params) ~f:(fun field ->
        not (List.mem (fields base) field ~equal:Sexp.equal))
    in
    print_s [%message "ok" ~_:(changed : Sexp.t list)]
;;

let%expect_test "overrides" =
  show "()";
  show "((levels 5) (base_half_spread_bps 4.5))";
  show "((soft_max_position (0.005)) (max_actions_per_sec 300))";
  [%expect
    {|
    (ok ())
    (ok ((levels 5) (base_half_spread_bps 4.5)))
    (ok ((max_actions_per_sec 300) (soft_max_position (0.005))))
    |}];
  return ()
;;

let%expect_test "rejected files" =
  show "((levels 0))";
  show "((levles 5))";
  show "((levels 5) (levels 6))";
  show "((symbol ETH))";
  show "((levels five))";
  show "levels";
  show "((levels 5 6))";
  [%expect
    {|
    (rejected ("invalid params" (errors ("levels must be in [1, 255]"))))
    (rejected ("unknown parameters" (levles)))
    (rejected ("field set twice" levels))
    (rejected ("the symbol cannot change" (from BTC) (to_ ETH)))
    (rejected
     ("bad parameter value"
      (Of_sexp_error "int_of_sexp: (Failure int_of_string)" (invalid_sexp five))))
    (rejected ("expected a list of (name value) fields" (sexp levels)))
    (rejected ("expected (name value)" (field (levels 5 6))))
    |}];
  return ()
;;

let%expect_test "load from a file" =
  let path = Filename_unix.temp_file "params" ".sexp" in
  Out_channel.write_all path ~data:"; quoting wider\n((base_half_spread_bps 6))\n";
  (match Params_file.load path ~base with
   | Ok params -> print_s [%message (params.base_half_spread_bps : float)]
   | Error error -> print_s [%sexp (error : Error.t)]);
  Core_unix.unlink path;
  [%expect {| (params.base_half_spread_bps 6) |}];
  return ()
;;
