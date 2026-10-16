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

let%expect_test "action rate grace and cooldown keys" =
  (* Left out of the base sexp at their defaults, still known names. The cooldown is a
     number of milliseconds or a span: leaving it out means none. *)
  show "((action_rate_grace_ms 2000) (action_rate_cooldown_ms 30000))";
  show "((action_rate_grace_ms 5000))";
  show "((action_rate_grace_ms -1))";
  show "((action_rate_cooldown_ms 0))";
  [%expect
    {|
    (ok ((action_rate_grace_ms 2s) (action_rate_cooldown_ms 30s)))
    (ok ())
    (rejected
     ("invalid params" (errors ("action_rate_grace_ms must be non-negative"))))
    (rejected
     ("invalid params" (errors ("action_rate_cooldown_ms must be positive"))))
    |}];
  return ()
;;

let%expect_test "durations as spans or integer milliseconds" =
  show "((requote_interval_ms 500ms) (order_ttl_ms 2m))";
  show "((requote_interval_ms 500) (order_ttl_ms 120000))";
  show "((requote_interval_ms 1000) (max_data_age_ms 5s))";
  show "((action_rate_cooldown_ms 30s))";
  [%expect
    {|
    (ok ((requote_interval_ms 500ms) (order_ttl_ms 2m)))
    (ok ((requote_interval_ms 500ms) (order_ttl_ms 2m)))
    (ok ())
    (ok ((action_rate_cooldown_ms 30s)))
    |}];
  return ()
;;

let%expect_test "toxicity gate and reference guard" =
  (* Left out of the base sexp while off. Listed fields replace the defaults; the others
     keep them, and durations may be integer milliseconds as at the top level. *)
  show "((toxicity_gate ()))";
  show "((toxicity_gate ((pull_at 0.9) (max_signal_age_ms 5000))))";
  show "((reference_guard ((band_bps 20) (grace_ms 500ms) (max_jump_bps (100)))))";
  [%expect
    {|
    (ok
     ((toxicity_gate
       ((widen_from 0.8) (pull_at 0.95) (max_extra_half_spread_bps 5)
        (skew_bps 2) (size_cut 0.5) (max_signal_age_ms 1m)))))
    (ok
     ((toxicity_gate
       ((widen_from 0.8) (pull_at 0.9) (max_extra_half_spread_bps 5) (skew_bps 2)
        (size_cut 0.5) (max_signal_age_ms 5s)))))
    (ok
     ((reference_guard
       ((band_bps 20) (grace_ms 500ms) (max_jump_bps (100))
        (max_reference_age_ms 30s) (stale_reference Pull)))))
    |}];
  return ()
;;

let%expect_test "toxicity gate and reference guard: fields keep the base's values" =
  let base =
    ok_exn
      (Params_file.apply
         base
         ~overrides:(Sexp.of_string "((toxicity_gate ((pull_at 0.9))))"))
  in
  (match
     Params_file.apply
       base
       ~overrides:(Sexp.of_string "((toxicity_gate ((widen_from 0.5))))")
   with
   | Ok params ->
     print_s [%sexp (params.toxicity_gate : Mm_core.Toxicity_gate.Config.t option)]
   | Error error -> print_s [%sexp (error : Error.t)]);
  [%expect
    {|
    (((widen_from 0.5) (pull_at 0.9) (max_extra_half_spread_bps 5) (skew_bps 2)
      (size_cut 0.5) (max_signal_age_ms 1m)))
    |}];
  return ()
;;

let%expect_test "toxicity gate and reference guard: rejected" =
  show "((toxicity_gate ((pull_at 0.5))))";
  show "((reference_guard ((band 20))))";
  show "((reference_guard 20))";
  [%expect
    {|
    (rejected
     ("invalid params"
      (errors
       ( "toxicity_gate: (\"invalid toxicity gate\" (\"widen_from must be below pull_at\")\
        \n (config\
        \n  ((widen_from 0.8) (pull_at 0.5) (max_extra_half_spread_bps 5) (skew_bps 2)\
        \n   (size_cut 0.5) (max_signal_age_ms 1m))))"))))
    (rejected ("unknown parameters" (in_ reference_guard) (band)))
    (rejected
     (reference_guard ("expected a list of (name value) fields" (sexp 20))))
    |}];
  return ()
;;
