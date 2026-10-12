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
    ("params reloaded, restarting the loop"(changes((levels 1))))
    stopping
    shutdown: cancelling 4 resting orders
    (starting(params((symbol BTC)(tick 1)(lot 0.00001)(order_size 0.001)(levels 1)(base_half_spread_bps 3)(level_spacing_bps 2)(skew_bps 4)(max_position 0.01)(max_notional 1500)(inventory_target 0)(requote_threshold_bps 1)(requote_interval_ms 1000)(order_ttl_ms 60000)(gamma 0.5)(vol_window 100)(max_vol_bps 10)(max_drawdown 50)(max_data_age_ms 5000)(flatten_slippage_bps 50)(max_actions_per_sec 100)(soft_max_position())(bump_budget 0))))
    (mode(from(Pulled No_market_data))(to_ Running))
    plan #1 gen 1: cancel 0, keep 0, place [buy 0.001@99970 sell 0.001@100030]
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
             | Params _ -> true
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
    ((outcome.reloads 1) ("(outcome.report).fills" 3) (params_lines 2)
     (fills_logged 3))
    ((ticks 57) (plans 6) (mismatches ()))
    |}];
  return ()
;;
