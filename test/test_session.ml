open! Core
open! Async
open Market_maker
module Session = Session.Make (Fake_venue)

let%expect_test "tick-to-order latency in the outcome" =
  Log.Global.set_output [];
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  (* Places take 30 ms, so a book arriving while a plan is in flight waits for it. *)
  let venue =
    Fake_venue.create
      ~time_source:(Time_source.read_only time_source)
      ~place_delay:(Time_ns.Span.of_int_ms 30)
      ()
  in
  Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
  let stop = Ivar.create () in
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      venue
      ~symbol:Fake_venue.btc
      ~params:(fun instrument ~mid -> Ok (Mm_core.Params.for_instrument instrument ~mid))
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 500) in
  let%bind () =
    Deferred.List.iter
      ~how:`Sequential
      [ "100000", "100020"; "100100", "100120"; "100300", "100320" ]
      ~f:(fun (bid, ask) ->
        Fake_venue.push_book venue ~bid ~ask;
        Session_helpers.advance time_source (Time_ns.Span.of_int_ms 10))
  in
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_sec 1.5) in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  let outcome = ok_exn outcome in
  print_s [%sexp (outcome.tick_to_order : Mm_core.Latency_histogram.Stats.t option)];
  print_endline
    (List.last_exn
       (String.split_lines (Market_maker.Session.Outcome.to_string_hum outcome)));
  print_s
    [%message
      (Fake_venue.closed venue : bool)
        (Fake_venue.resting venue : Exchange_core.Open_order.t list)];
  [%expect
    {|
    (((count 3) (p50 0s) (p99 20ms) (max 20ms)))
    tick-to-order    n=3 p50=0ns p99=20ms max=20ms
    (("Fake_venue.closed venue" true) ("Fake_venue.resting venue" ()))
    |}];
  return ()
;;

let%expect_test "params reloads: rejected, applied, unchanged" =
  Session_helpers.print_logs ();
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let venue = Fake_venue.create ~time_source:(Time_source.read_only time_source) () in
  Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
  (* Stands in for the params file, read again on every reload. *)
  let overrides = ref "((levels 2))" in
  let params instrument ~mid =
    Params_file.apply
      (Mm_core.Params.for_instrument instrument ~mid)
      ~overrides:(Sexp.of_string !overrides)
  in
  (* Stands in for SIGHUP. *)
  let reload_r, reload_w = Pipe.create () in
  let stop = Ivar.create () in
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ~reload:reload_r
      venue
      ~symbol:Fake_venue.btc
      ~params
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  let step ?(after = Time_ns.Span.of_int_ms 500) label =
    let%bind () = Session_helpers.advance time_source after in
    let%bind () = Log.Global.flushed () in
    print_endline ("--- " ^ label);
    return ()
  in
  let reload label new_overrides =
    overrides := new_overrides;
    Pipe.write_without_pushback reload_w ();
    let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 500) in
    Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
    step label
  in
  let%bind () = step "started" in
  let%bind () = reload "levels 0 is rejected" "((levels 0))" in
  let%bind () = reload "levels 1 applies" "((levels 1))" in
  let%bind () = reload "same again" "((levels 1))" in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  let%bind () = Log.Global.flushed () in
  let outcome = ok_exn outcome in
  print_s
    [%message
      (outcome.reloads : int)
        (outcome.report.plans : int)
        (Fake_venue.resting venue : Exchange_core.Open_order.t list)];
  [%expect
    {|
    (starting(params((symbol BTC)(tick 1)(lot 0.00001)(order_size 0.001)(levels 2)(base_half_spread_bps 3)(level_spacing_bps 2)(skew_bps 4)(max_position 0.01)(max_notional 1500)(inventory_target 0)(requote_threshold_bps 1)(requote_interval_ms 1000)(order_ttl_ms 60000)(gamma 0.5)(vol_window 100)(max_vol_bps 10)(max_drawdown 50)(max_data_age_ms 5000)(flatten_slippage_bps 50)(max_actions_per_sec 100)(soft_max_position())(bump_budget 0))))
    (mode(from(Pulled No_market_data))(to_ Running))
    plan #1 gen 1: cancel 0, keep 0, place [buy 0.001@99970 buy 0.001@99950 sell 0.001@100030 sell 0.001@100050]
    --- started
    ("params rejected, keeping the current ones"(error("invalid params"(errors("levels must be in [1, 255]")))))
    --- levels 0 is rejected
    ("params updated"(params((symbol BTC)(tick 1)(lot 0.00001)(order_size 0.001)(levels 1)(base_half_spread_bps 3)(level_spacing_bps 2)(skew_bps 4)(max_position 0.01)(max_notional 1500)(inventory_target 0)(requote_threshold_bps 1)(requote_interval_ms 1000)(order_ttl_ms 60000)(gamma 0.5)(vol_window 100)(max_vol_bps 10)(max_drawdown 50)(max_data_age_ms 5000)(flatten_slippage_bps 50)(max_actions_per_sec 100)(soft_max_position())(bump_budget 0))))
    ("params reloaded"(changes((levels 1))))
    plan #2 gen 1: cancel 2, keep 2, place []
    --- levels 1 applies
    params reload: nothing changed
    --- same again
    stopping
    shutdown: cancelling 2 resting orders
    ((outcome.reloads 1) ("(outcome.report).plans" 2)
     ("Fake_venue.resting venue" ()))
    |}];
  return ()
;;

let%expect_test "a shadow with one level logs its differing plans" =
  Session_helpers.print_logs ();
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let venue = Fake_venue.create ~time_source:(Time_source.read_only time_source) () in
  Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
  let with_overrides overrides instrument ~mid =
    Params_file.apply
      (Mm_core.Params.for_instrument instrument ~mid)
      ~overrides:(Sexp.of_string overrides)
  in
  let stop = Ivar.create () in
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ~shadow_params:(with_overrides "((levels 1))")
      venue
      ~symbol:Fake_venue.btc
      ~params:(with_overrides "((levels 2))")
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 500) in
  Fake_venue.push_book venue ~bid:"100090" ~ask:"100110";
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 1500) in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  let%bind () = Log.Global.flushed () in
  let outcome = ok_exn outcome in
  print_endline
    (List.last_exn
       (String.split_lines (Market_maker.Session.Outcome.to_string_hum outcome)));
  [%expect
    {|
    (starting(params((symbol BTC)(tick 1)(lot 0.00001)(order_size 0.001)(levels 2)(base_half_spread_bps 3)(level_spacing_bps 2)(skew_bps 4)(max_position 0.01)(max_notional 1500)(inventory_target 0)(requote_threshold_bps 1)(requote_interval_ms 1000)(order_ttl_ms 60000)(gamma 0.5)(vol_window 100)(max_vol_bps 10)(max_drawdown 50)(max_data_age_ms 5000)(flatten_slippage_bps 50)(max_actions_per_sec 100)(soft_max_position())(bump_budget 0))))
    shadow plan differs: live cancel 0, keep 0, place [buy 0.001@99970 buy 0.001@99950 sell 0.001@100030 sell 0.001@100050] | shadow cancel 0, keep 0, place [buy 0.001@99970 sell 0.001@100030]
    (mode(from(Pulled No_market_data))(to_ Running))
    plan #1 gen 1: cancel 0, keep 0, place [buy 0.001@99970 buy 0.001@99950 sell 0.001@100030 sell 0.001@100050]
    shadow plan differs: live cancel 4, keep 0, place [buy 0.001@99819 buy 0.001@99799 sell 0.001@100381 sell 0.001@100401] | shadow cancel 4, keep 0, place [buy 0.001@99819 sell 0.001@100381]
    plan #2 gen 2: cancel 4, keep 0, place [buy 0.001@99819 buy 0.001@99799 sell 0.001@100381 sell 0.001@100401]
    shadow plan differs: live cancel 0, keep 0, place [] | shadow cancel 2, keep 2, place []
    stopping
    shutdown: cancelling 4 resting orders
    shadow plans     3 of 3 differ
    |}];
  return ()
;;

let%expect_test "the strategy log of a session replays to the same plans" =
  Log.Global.set_output [];
  let path = Filename_unix.temp_file "session" ".log" in
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let venue = Fake_venue.create ~time_source:(Time_source.read_only time_source) () in
  Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
  let reload_r, reload_w = Pipe.create () in
  let levels = ref 3 in
  let stop = Ivar.create () in
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ~reload:reload_r
      ~strategy_log:path
      venue
      ~symbol:Fake_venue.btc
      ~params:(fun instrument ~mid ->
        Ok { (Mm_core.Params.for_instrument instrument ~mid) with levels = !levels })
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  (* Opening the log file runs in a thread, outside the synthetic clock: wait on the wall
     clock for the first quotes before driving the session. *)
  let%bind () =
    Session_helpers.wait_until ~what:"first quotes" (fun () ->
      not (List.is_empty (Fake_venue.resting venue)))
  in
  let%bind () =
    Deferred.List.iter
      ~how:`Sequential
      [ "100000", "100020"; "100100", "100120"; "100050", "100070"; "99900", "99920" ]
      ~f:(fun (bid, ask) ->
        Fake_venue.push_book venue ~bid ~ask;
        Fake_venue.fill_best venue Buy;
        Session_helpers.advance time_source (Time_ns.Span.of_int_ms 700))
  in
  levels := 1;
  Pipe.write_without_pushback reload_w ();
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 500) in
  Fake_venue.push_book venue ~bid:"99950" ~ask:"99970";
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 1500) in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  let outcome = ok_exn outcome in
  let%bind events = Strategy_log.load path >>| ok_exn in
  Core_unix.unlink path;
  let count f = List.count events ~f in
  print_s
    [%message
      (outcome.reloads : int)
        (outcome.report.fills : int)
        ~params_lines:
          (count (function
             | Params _ | Update_params _ -> true
             | _ -> false)
           : int)
        ~fills_logged:
          (count (function
             | Input (Fill _) -> true
             | _ -> false)
           : int)];
  print_s [%sexp (ok_exn (Strategy_log.Replay.run events) : Strategy_log.Replay.t)];
  [%expect
    {|
    ((outcome.reloads 1) ("(outcome.report).fills" 4) (params_lines 2)
     (fills_logged 4))
    ((ticks 60) (plans 6) (mismatches ()))
    |}];
  return ()
;;

let%expect_test "a reload mid-run moves the quotes without a cancel-all" =
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let venue = Fake_venue.create ~time_source:(Time_source.read_only time_source) () in
  Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
  let spread = ref 3 in
  let params instrument ~mid =
    Ok
      { (Mm_core.Params.for_instrument instrument ~mid) with
        levels = 1
      ; base_half_spread_bps = Float.of_int !spread
      }
  in
  let reload_r, reload_w = Pipe.create () in
  let stop = Ivar.create () in
  (* Only the lines that would show a restart or a cancel-all, and the reload itself. *)
  let lines = Queue.create () in
  Log.Global.set_output
    [ Log.Output.create
        ~flush:(fun () -> return ())
        (fun messages ->
          Queue.iter messages ~f:(fun m -> Queue.enqueue lines (Log.Message.message m));
          return ())
    ];
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ~reload:reload_r
      venue
      ~symbol:Fake_venue.btc
      ~params
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  let quotes () =
    List.map (Fake_venue.resting venue) ~f:(fun o -> Exchange_core.Price.to_string o.px)
    |> List.sort ~compare:String.compare
  in
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 500) in
  let before = quotes () in
  spread := 10;
  Pipe.write_without_pushback reload_w ();
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 500) in
  let after = quotes () in
  let%bind () = Log.Global.flushed () in
  let during_run = Queue.to_list lines in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  let outcome = ok_exn outcome in
  let mentions word = List.exists during_run ~f:(String.is_substring ~substring:word) in
  print_s
    [%message
      (before : string list)
        (after : string list)
        (outcome.reloads : int)
        ~restarted:(mentions "starting" && mentions "stopping" : bool)
        ~cancel_all:(mentions "shutdown" : bool)
        ~reloaded:(mentions "params reloaded" : bool)];
  [%expect
    {|
    ((before (100030 99970)) (after (100100 99900)) (outcome.reloads 1)
     (restarted false) (cancel_all false) (reloaded true))
    |}];
  return ()
;;

(* A reconnect followed by a requote burst (the mid flips by 10 bps every 2 ms, so each
   tick replaces the ladder), with and without the reconnect: the shadow strategies and
   the strategy log's mirror start the same grace period as the live loop. *)
let reconnect_burst ~reconnect =
  Log.Global.set_output [];
  let path = Filename_unix.temp_file "session" ".log" in
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let venue = Fake_venue.create ~time_source:(Time_source.read_only time_source) () in
  Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
  let params ~levels instrument ~mid =
    Ok
      { (Mm_core.Params.for_instrument instrument ~mid) with
        levels
      ; max_actions_per_sec = 40
      ; action_rate_grace_ms = 1_000
      }
  in
  let stop = Ivar.create () in
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ~shadow_params:(params ~levels:1)
      ~strategy_log:path
      venue
      ~symbol:Fake_venue.btc
      ~params:(params ~levels:3)
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  let%bind () =
    Session_helpers.wait_until ~what:"first quotes" (fun () ->
      not (List.is_empty (Fake_venue.resting venue)))
  in
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_sec 3) in
  if reconnect then Fake_venue.reconnect venue;
  let%bind () =
    Deferred.List.iter ~how:`Sequential (List.range 0 100) ~f:(fun i ->
      let mid = if i % 2 = 0 then 100_000 else 100_100 in
      Fake_venue.push_book
        venue
        ~bid:(Int.to_string (mid - 10))
        ~ask:(Int.to_string (mid + 10));
      let%bind () =
        Time_source.advance_by_alarms_by time_source (Time_ns.Span.of_int_ms 2)
      in
      Scheduler.yield_until_no_jobs_remain ())
  in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  let outcome = ok_exn outcome in
  let%bind events = Strategy_log.load path >>| ok_exn in
  Core_unix.unlink path;
  let shadow = Option.value_exn outcome.shadow in
  let replay = ok_exn (Strategy_log.Replay.run events) in
  print_s
    [%message
      (reconnect : bool)
        ~live:(outcome.report.mode : Mm_core.Strategy.Mode.t)
        ~shadow_mirror:(shadow.live_mode : Mm_core.Strategy.Mode.t)
        ~shadow:(shadow.shadow_mode : Mm_core.Strategy.Mode.t)
        ~resyncs_logged:
          (List.count events ~f:(function
             | Resync _ -> true
             | _ -> false)
           : int)
        ~replay_ticks:(replay.ticks : int)
        ~replay_mismatches:(List.length replay.mismatches : int)];
  return ()
;;

let%expect_test "after a reconnect, a requote burst halts neither the loop nor its \
                 mirrors"
  =
  let%bind () = reconnect_burst ~reconnect:true in
  let%bind () = reconnect_burst ~reconnect:false in
  [%expect
    {|
    ((reconnect true) (live Running) (shadow_mirror Running) (shadow Running)
     (resyncs_logged 1) (replay_ticks 515) (replay_mismatches 0))
    ((reconnect false) (live (Halted (Max_action_rate (actions 48))))
     (shadow_mirror (Halted (Max_action_rate (actions 48)))) (shadow Running)
     (resyncs_logged 0) (replay_ticks 133) (replay_mismatches 0))
    |}];
  return ()
;;

let%expect_test "the order log of a session: places, acks, a fill, the final cancels" =
  Log.Global.set_output [];
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let venue = Fake_venue.create ~time_source:(Time_source.read_only time_source) () in
  Fake_venue.push_book venue ~bid:"99990" ~ask:"100010";
  let path = Filename_unix.temp_file "session" ".csv" in
  let stop = Ivar.create () in
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ~order_log:{ path; venue = "fake" }
      venue
      ~symbol:Fake_venue.btc
      ~params:(fun instrument ~mid ->
        Ok { (Mm_core.Params.for_instrument instrument ~mid) with levels = 1 })
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 500) in
  Fake_venue.fill_best venue Buy;
  let%bind () = Session_helpers.advance time_source (Time_ns.Span.of_int_ms 100) in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  ok_exn outcome |> (ignore : Market_maker.Session.Outcome.t -> unit);
  let%bind contents = Reader.file_contents path in
  (* The first plan's moment depends on file IO outside the synthetic clock, so the local
     times are only checked to be in order and after the start. *)
  let start = Time_ns.to_int_ns_since_epoch Session_helpers.start_time in
  let lines = String.split_lines contents in
  let local_times =
    List.tl_exn lines
    |> List.map ~f:(fun line -> Int.of_string (List.hd_exn (String.split line ~on:',')))
  in
  print_s
    [%message
      ""
        ~in_order:(List.is_sorted local_times ~compare:Int.compare : bool)
        ~after_start:(List.for_all local_times ~f:(fun t -> t >= start) : bool)];
  List.iteri lines ~f:(fun i line ->
    if i = 0
    then print_endline line
    else (
      match String.lsplit2 line ~on:',' with
      | Some (_, rest) -> print_endline ("T," ^ rest)
      | None -> print_endline line));
  [%expect
    {|
    ((in_order true) (after_start true))
    local_ts,venue_ts,venue,symbol,event,side,price,size,order_id,client_order_id,status,trade_id,fee,detail
    T,,fake,BTC,place,buy,99970,0.001,,0x42544300000000000000000000000000,,,,
    T,,fake,BTC,place,sell,100030,0.001,,0x42544300000000000100000000000000,,,,
    T,,fake,BTC,ack,buy,99970,0.001,1,0x42544300000000000000000000000000,resting,,,
    T,,fake,BTC,ack,sell,100030,0.001,2,0x42544300000000000100000000000000,resting,,,
    T,0,fake,BTC,update,buy,99970,0,1,0x42544300000000000000000000000000,filled,,,filled 0
    T,0,fake,BTC,fill,buy,99970,0.001,1,0x42544300000000000000000000000000,maker,1,0,
    T,,fake,BTC,cancel_all,,,,,,,,,
    T,0,fake,BTC,update,sell,100030,0,2,0x42544300000000000100000000000000,cancelled,,,filled 0
    T,,fake,BTC,cancel_all_ack,,,,,,ok,,,
    |}];
  return ()
;;
