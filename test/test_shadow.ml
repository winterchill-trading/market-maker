open! Core
open! Async
open Exchange_core
open Market_maker

let ms n = n * 1_000_000

let book ~time ~bid ~ask : Strategy_input.t =
  let level px : L2.Level.t =
    { px = Price.of_string px; sz = Size.of_string "1"; n = 1 }
  in
  Book
    { symbol = Mm_core.Params.btc.symbol
    ; time = ms time
    ; bids = [ level bid ]
    ; asks = [ level ask ]
    }
;;

let print_difference ~live ~shadow =
  printf
    "live   %s\nshadow %s\n"
    (Shadow.Plan.to_string_hum live)
    (Shadow.Plan.to_string_hum shadow)
;;

let run shadow_overrides =
  let live = Mm_core.Params.btc in
  let shadow =
    ok_exn (Params_file.apply live ~overrides:(Sexp.of_string shadow_overrides))
  in
  let t = Shadow.create ~live ~shadow in
  List.iter
    [ 0, book ~time:0 ~bid:"99990" ~ask:"100010"
    ; 10, Strategy_input.Open_orders []
    ; 1500, book ~time:1500 ~bid:"100090" ~ask:"100110"
    ]
    ~f:(fun (at, input) ->
      let name : Strategy_input.t -> string = function
        | Book _ -> "book"
        | Fill _ -> "fill"
        | Open_orders _ -> "open orders"
        | Account _ -> "account"
      in
      printf "-- %s at %dms\n" (name input) at;
      Shadow.on_input t input ~now:(ms at) ~on_difference:print_difference);
  print_s [%sexp (Shadow.stats t : Shadow.Stats.t)]
;;

let%expect_test "same parameters never differ" =
  run "()";
  [%expect
    {|
    -- book at 0ms
    -- open orders at 10ms
    -- book at 1500ms
    ((plans 2) (differing 0) (live_mode Running) (shadow_mode Running))
    |}];
  return ()
;;

let%expect_test "a wider, shorter ladder" =
  run "((levels 1) (base_half_spread_bps 5))";
  [%expect
    {|
    -- book at 0ms
    live   cancel 0, keep 0, place [buy 0.001@99970 buy 0.001@99950 buy 0.001@99930 sell 0.001@100030 sell 0.001@100050 sell 0.001@100070]
    shadow cancel 0, keep 0, place [buy 0.001@99950 sell 0.001@100050]
    -- open orders at 10ms
    -- book at 1500ms
    live   cancel 0, keep 0, place [buy 0.001@99819 buy 0.001@99799 buy 0.001@99779 sell 0.001@100381 sell 0.001@100401 sell 0.001@100421]
    shadow cancel 0, keep 0, place [buy 0.001@99799 sell 0.001@100401]
    ((plans 2) (differing 2) (live_mode Running) (shadow_mode Running))
    |}];
  return ()
;;

let%expect_test "updating the shadow to the live parameters keeps its state" =
  let live = Mm_core.Params.btc in
  let shadow = { live with levels = 1 } in
  let t = Shadow.create ~live ~shadow in
  let feed at input =
    Shadow.on_input t input ~now:(ms at) ~on_difference:print_difference
  in
  feed 0 (book ~time:0 ~bid:"99990" ~ask:"100010");
  feed 10 (Strategy_input.Open_orders []);
  print_s [%sexp (Shadow.update_params t ~live ~shadow:live : unit Or_error.t)];
  print_s
    [%sexp
      (Shadow.update_params t ~live ~shadow:{ live with levels = 0 } : unit Or_error.t)];
  feed 1500 (book ~time:1500 ~bid:"100090" ~ask:"100110");
  print_s [%sexp (Shadow.stats t : Shadow.Stats.t)];
  [%expect
    {|
    live   cancel 0, keep 0, place [buy 0.001@99970 buy 0.001@99950 buy 0.001@99930 sell 0.001@100030 sell 0.001@100050 sell 0.001@100070]
    shadow cancel 0, keep 0, place [buy 0.001@99970 sell 0.001@100030]
    (Ok ())
    (Error ("invalid params" (errors ("levels must be in [1, 255]"))))
    ((plans 2) (differing 1) (live_mode Running) (shadow_mode Running))
    |}];
  return ()
;;

let%expect_test "a requote burst right after on_resync halts neither strategy" =
  let live =
    { Mm_core.Params.btc with
      max_actions_per_sec = 40
    ; action_rate_grace_ms = Time_ns.Span.of_int_ms 1_000
    }
  in
  let burst ~resync =
    let t = Shadow.create ~live ~shadow:{ live with levels = 1 } in
    if resync then Shadow.on_resync t ~now:(ms 10_000);
    (* The mid flips by 10 bps every 2 ms, so each tick replaces the ladder. *)
    List.iter (List.range 10_000 10_200 ~stride:2) ~f:(fun at ->
      let mid = if at / 2 % 2 = 0 then 100_000 else 100_100 in
      Shadow.on_input
        t
        (book ~time:at ~bid:(Int.to_string (mid - 10)) ~ask:(Int.to_string (mid + 10)))
        ~now:(ms at)
        ~on_difference:(fun ~live:_ ~shadow:_ -> ());
      Shadow.on_input
        t
        (Open_orders [])
        ~now:(ms at)
        ~on_difference:(fun ~live:_ ~shadow:_ -> ()));
    print_s
      [%message
        (resync : bool)
          ~live:(Shadow.live_mode t : Mm_core.Strategy.Mode.t)
          ~shadow:(Shadow.shadow_mode t : Mm_core.Strategy.Mode.t)]
  in
  burst ~resync:false;
  burst ~resync:true;
  [%expect
    {|
    ((resync false) (live (Halted (Max_action_rate (actions 42))))
     (shadow (Halted (Max_action_rate (actions 42)))))
    ((resync true) (live Running) (shadow Running))
    |}];
  return ()
;;
