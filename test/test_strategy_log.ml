open! Core
open! Async
open Exchange_core
open Market_maker

let ms n = n * 1_000_000
let btc = Mm_core.Params.btc.symbol

let book ~time ~bid ~ask : Strategy_input.t =
  let level px : L2.Level.t =
    { px = Price.of_string px; sz = Size.of_string "1"; n = 1 }
  in
  Book { symbol = btc; time = ms time; bids = [ level bid ]; asks = [ level ask ] }
;;

let fill ~time ~tid ~side ~px : Strategy_input.t =
  Fill
    { trade_id = Trade_id.of_int tid
    ; order_id = Order_id.of_int tid
    ; client_order_id = None
    ; symbol = btc
    ; side
    ; px = Price.of_string px
    ; size = Size.of_string "0.001"
    ; fee = Usd.zero
    ; is_maker = true
    ; time = ms time
    ; closed_pnl = None
    }
;;

(* A short session: books, a fill, snapshots, a reload to one level. *)
let script : [ `Input of int * Strategy_input.t | `Reload of string ] list =
  [ `Input (0, book ~time:0 ~bid:"99990" ~ask:"100010")
  ; `Input (5, Open_orders [])
  ; `Input (300, book ~time:300 ~bid:"100000" ~ask:"100020")
  ; `Input (400, fill ~time:400 ~tid:1 ~side:Buy ~px:"99970")
  ; `Input (1500, book ~time:1500 ~bid:"99950" ~ask:"99970")
  ; `Input (1510, Open_orders [])
  ; `Reload "((levels 1))"
  ; `Input (2000, book ~time:2000 ~bid:"99960" ~ask:"99980")
  ; `Input (3200, book ~time:3200 ~bid:"99990" ~ask:"100010")
  ]
;;

let record () =
  let events = Queue.create () in
  let params = Mm_core.Params.btc in
  let log = Strategy_log.of_writer (Queue.enqueue events) ~params in
  List.iter script ~f:(function
    | `Input (at, input) -> Strategy_log.on_input log input ~now:(ms at)
    | `Reload overrides ->
      Strategy_log.update_params
        log
        (ok_exn (Params_file.apply params ~overrides:(Sexp.of_string overrides)))
      |> ok_exn);
  Queue.to_list events
;;

let print_replay events =
  match Strategy_log.Replay.run events with
  | Error error -> print_s [%sexp (error : Error.t)]
  | Ok { ticks; plans; mismatches } ->
    print_s [%message (ticks : int) (plans : int)];
    List.iter mismatches ~f:(fun m ->
      print_s
        [%message
          "mismatch"
            ~line:(m.line : int)
            ~logged:(List.length m.logged : int)
            ~replayed:(List.length m.replayed : int)])
;;

let%expect_test "replaying a log gives the same plans" =
  let events = record () in
  List.iter events ~f:(function
    | Params p -> printf "params, %d levels\n" p.levels
    | Update_params p -> printf "update params, %d levels\n" p.levels
    | Input input ->
      printf
        "input %s\n"
        (match input with
         | Book _ -> "book"
         | Fill _ -> "fill"
         | Open_orders _ -> "open orders"
         | Account _ -> "account")
    | Resync { now } -> printf "resync at %dms\n" (now / 1_000_000)
    | Tick { now; plan } ->
      printf "tick at %dms: %d actions\n" (now / 1_000_000) (List.length plan));
  print_replay events;
  [%expect
    {|
    params, 3 levels
    input book
    tick at 0ms: 6 actions
    input open orders
    tick at 5ms: 0 actions
    input book
    tick at 300ms: 6 actions
    input fill
    tick at 400ms: 0 actions
    input book
    tick at 1500ms: 0 actions
    input open orders
    tick at 1510ms: 0 actions
    update params, 1 levels
    input book
    tick at 2000ms: 2 actions
    input book
    tick at 3200ms: 0 actions
    ((ticks 8) (plans 3))
    |}];
  return ()
;;

let%expect_test "a changed plan or a missing header is caught" =
  let events = record () in
  let tampered =
    List.mapi events ~f:(fun i event ->
      match event with
      | Tick { now; plan = _ :: _ as plan } when i < 4 ->
        Strategy_log.Event.Tick { now; plan = List.tl_exn plan }
      | event -> event)
  in
  print_replay tampered;
  print_replay (List.tl_exn events);
  [%expect
    {|
    ((ticks 8) (plans 3))
    (mismatch (line 3) (logged 5) (replayed 6))
    "a strategy log starts with a Params line"
    |}];
  return ()
;;

let%expect_test "file round trip" =
  let path = Filename_unix.temp_file "strategy" ".log" in
  let%bind log = Strategy_log.create path ~params:Mm_core.Params.btc in
  List.iter script ~f:(function
    | `Input (at, input) -> Strategy_log.on_input log input ~now:(ms at)
    | `Reload _ -> ());
  let%bind () = Strategy_log.close log in
  let%bind events = Strategy_log.load path in
  let lines = List.length (In_channel.read_lines path) in
  Core_unix.unlink path;
  let events = ok_exn events in
  print_s [%message (lines : int) ~events:(List.length events : int)];
  print_replay events;
  [%expect {|
    ((lines 17) (events 17))
    ((ticks 8) (plans 3))
    |}];
  return ()
;;

let%expect_test "a resync before a requote burst replays; without it the burst halts" =
  let params =
    { Mm_core.Params.btc with max_actions_per_sec = 40; action_rate_grace_ms = 1_000 }
  in
  let events = Queue.create () in
  let log = Strategy_log.of_writer (Queue.enqueue events) ~params in
  Strategy_log.on_resync log ~now:(ms 10_000);
  (* The mid flips by 10 bps every 2 ms, so each tick replaces the ladder. *)
  List.iter (List.range 10_000 10_200 ~stride:2) ~f:(fun at ->
    let mid = if at / 2 % 2 = 0 then 100_000 else 100_100 in
    Strategy_log.on_input
      log
      (book ~time:at ~bid:(Int.to_string (mid - 10)) ~ask:(Int.to_string (mid + 10)))
      ~now:(ms at);
    Strategy_log.on_input log (Open_orders []) ~now:(ms at));
  let events = Queue.to_list events in
  print_s [%sexp (Strategy_log.mode log : Mm_core.Strategy.Mode.t)];
  print_replay events;
  let without_resync =
    List.filter events ~f:(function
      | Resync _ -> false
      | _ -> true)
  in
  let replay = ok_exn (Strategy_log.Replay.run without_resync) in
  print_s
    [%message "without the resync" ~mismatches:(List.length replay.mismatches : int)];
  [%expect
    {|
    Running
    ((ticks 200) (plans 100))
    ("without the resync" (mismatches 93))
    |}];
  return ()
;;
