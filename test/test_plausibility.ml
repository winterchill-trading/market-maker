open! Core
open! Async
open Market_maker
module Session = Session.Make (Fake_venue)

let ms = Time_ns.Span.of_int_ms

(* Runs a session on a fake venue with these params overrides, then [script] with a step
   function that re-pushes the venue's book (it goes stale after 5 s otherwise), advances
   the clock and prints what was logged under [label]. *)
let run ~overrides ?reference ?toxicity script =
  Session_helpers.print_logs ();
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let venue = Fake_venue.create ~time_source:(Time_source.read_only time_source) () in
  let book = ref ("99990", "100010") in
  let push () =
    let bid, ask = !book in
    Fake_venue.push_book venue ~bid ~ask
  in
  push ();
  let stop = Ivar.create () in
  let outcome =
    Session.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ?reference
      ?toxicity
      venue
      ~symbol:Fake_venue.btc
      ~params:(fun instrument ~mid ->
        Params_file.apply
          { (Mm_core.Params.for_instrument instrument ~mid) with levels = 1 }
          ~overrides:(Sexp.of_string overrides))
      ~summary_interval:(Time_ns.Span.of_int_sec 600)
      ~stop:(Ivar.read stop)
  in
  let step ?bid_ask ?(after = ms 500) label =
    Option.iter bid_ask ~f:(fun b -> book := b);
    push ();
    let%bind () = Session_helpers.advance time_source after in
    push ();
    let%bind () = Session_helpers.advance time_source (ms 10) in
    let%bind () = Log.Global.flushed () in
    print_endline ("--- " ^ label);
    return ()
  in
  let%bind () = script ~step in
  Ivar.fill_exn stop ();
  let%bind outcome = Session_helpers.advance_until time_source outcome in
  let%bind () = Log.Global.flushed () in
  let outcome = ok_exn outcome in
  print_s
    [%message
      (outcome.plausibility : (string * int) list)
        (outcome.report.mode : Mm_core.Strategy.Mode.t)];
  return ()
;;

(* Only the lines about plans, modes and plausibility. *)
let quiet () =
  Log.Global.set_output
    [ Log.Output.create
        ~flush:(fun () -> return ())
        (fun messages ->
          Queue.iter messages ~f:(fun m ->
            let line = Log.Message.message m in
            if List.exists
                 [ "plan #"; "(mode"; "reference"; "toxic"; "plausibility"; "gate" ]
                 ~f:(fun prefix -> String.is_substring line ~substring:prefix)
            then print_endline line);
          return ())
    ]
;;

let%expect_test "a frozen reference pulls the quotes; a fresh one resumes them" =
  let reference_r, reference_w = Pipe.create () in
  let reference px =
    Pipe.write_without_pushback reference_w (Exchange_core.Price.of_string px)
  in
  let%bind () =
    run
      ~overrides:
        "((reference_guard ((band_bps 20) (grace_ms 500) (max_reference_age_ms 2s))))"
      ~reference:reference_r
      (fun ~step ->
         quiet ();
         reference "100000";
         let%bind () = step "reference at the mid: quoting" in
         (* The venue moves 50 bps; the reference stays where it was. *)
         let%bind () =
           step ~bid_ask:("100490", "100510") "venue moved: requoted, pulled after 500 ms"
         in
         let%bind () = step "still diverged: nothing sent" in
         reference "100500";
         let%bind () = step "the reference catches up: quoting" in
         (* The reference stops updating altogether. *)
         let%bind () = step ~after:(ms 2500) "no reference for 2.5 s: pulled" in
         reference "100500";
         step "a reference again: quoting")
  in
  [%expect
    {|
    (starting(params((symbol BTC)(tick 1)(lot 0.00001)(order_size 0.001)(levels 1)(base_half_spread_bps 3)(level_spacing_bps 2)(skew_bps 4)(max_position 0.01)(max_notional 1500)(inventory_target 0)(requote_threshold_bps 1)(requote_interval_ms 1s)(order_ttl_ms 1m)(gamma 0.5)(vol_window 100)(max_vol_bps 10)(max_drawdown 50)(max_data_age_ms 5s)(flatten_slippage_bps 50)(max_actions_per_sec 100)(soft_max_position())(bump_budget 0)(reference_guard((band_bps 20)(grace_ms 500ms)(max_jump_bps())(max_reference_age_ms 2s)(stale_reference Pull))))))
    (mode(from(Pulled No_market_data))(to_ Running))
    plan #1 gen 1: cancel 0, keep 0, place [buy 0.001@99970 sell 0.001@100030]
    --- reference at the mid: quoting
    plan #2 gen 2: cancel 2, keep 0, place [buy 0.001@100346 sell 0.001@100654]
    (plausibility(event(Reference(Diverged(divergence_bps 50)(held_ms 500)(venue_mid 100500)(reference_mid 100000)))))
    (mode(from Running)(to_(Pulled(Reference_divergence(divergence_bps 50)(held_ms 500)))))
    plan #3 gen 2: cancel 2, keep 0, place []
    --- venue moved: requoted, pulled after 500 ms
    --- still diverged: nothing sent
    (plausibility(event(Reference Resumed)))
    (mode(from(Pulled(Reference_divergence(divergence_bps 50)(held_ms 500))))(to_ Running))
    plan #4 gen 3: cancel 0, keep 0, place [buy 0.001@100353 sell 0.001@100647]
    --- the reference catches up: quoting
    (plausibility(event(Reference(Reference_missing(age_ms(2470))))))
    (mode(from Running)(to_(Pulled(Reference_missing(age_ms(2470))))))
    plan #5 gen 3: cancel 2, keep 0, place []
    --- no reference for 2.5 s: pulled
    (plausibility(event(Reference Resumed)))
    (mode(from(Pulled(Reference_missing(age_ms(2470)))))(to_ Running))
    plan #6 gen 4: cancel 0, keep 0, place [buy 0.001@100362 sell 0.001@100638]
    --- a reference again: quoting
    ((outcome.plausibility
      (("guard diverged" 1) ("guard reference_missing" 1) ("guard resumed" 2)))
     ("(outcome.report).mode" Running))
    |}];
  return ()
;;

let%expect_test "a toxic signal widens, then pulls, then clears" =
  let toxicity_r, toxicity_w = Pipe.create () in
  let toxicity signal imbalance =
    Pipe.write_without_pushback toxicity_w { Toxicity_source.Signal.signal; imbalance }
  in
  let%bind () =
    run ~overrides:"((toxicity_gate ()))" ~toxicity:toxicity_r (fun ~step ->
      quiet ();
      toxicity 0.5 0.1;
      let%bind () = step "signal 0.5: normal" in
      toxicity 0.875 0.8;
      let%bind () = step ~after:(ms 1100) "signal 0.875: wider, shifted up, smaller" in
      toxicity 0.97 0.9;
      let%bind () = step "signal 0.97: pulled" in
      toxicity 0.2 0.;
      step ~after:(ms 1100) "signal 0.2: quoting as before")
  in
  [%expect
    {|
    (starting(params((symbol BTC)(tick 1)(lot 0.00001)(order_size 0.001)(levels 1)(base_half_spread_bps 3)(level_spacing_bps 2)(skew_bps 4)(max_position 0.01)(max_notional 1500)(inventory_target 0)(requote_threshold_bps 1)(requote_interval_ms 1s)(order_ttl_ms 1m)(gamma 0.5)(vol_window 100)(max_vol_bps 10)(max_drawdown 50)(max_data_age_ms 5s)(flatten_slippage_bps 50)(max_actions_per_sec 100)(soft_max_position())(bump_budget 0)(toxicity_gate((widen_from 0.8)(pull_at 0.95)(max_extra_half_spread_bps 5)(skew_bps 2)(size_cut 0.5)(max_signal_age_ms 1m))))))
    (mode(from(Pulled No_market_data))(to_ Running))
    plan #1 gen 1: cancel 0, keep 0, place [buy 0.001@99970 sell 0.001@100030]
    --- signal 0.5: normal
    (plausibility(event(Toxicity(Widening(signal 0.875)))))
    plan #2 gen 2: cancel 2, keep 0, place [buy 0.00075@99952 sell 0.00075@100064]
    --- signal 0.875: wider, shifted up, smaller
    (plausibility(event(Toxicity(Pulled(signal 0.97)))))
    (mode(from Running)(to_(Pulled(Toxic_flow(signal 0.97)))))
    plan #3 gen 2: cancel 2, keep 0, place []
    --- signal 0.97: pulled
    (plausibility(event(Toxicity Cleared)))
    (mode(from(Pulled(Toxic_flow(signal 0.97))))(to_ Running))
    plan #4 gen 3: cancel 0, keep 0, place [buy 0.001@99970 sell 0.001@100030]
    --- signal 0.2: quoting as before
    ((outcome.plausibility
      (("gate cleared" 1) ("gate pulled" 1) ("gate widening" 1)))
     ("(outcome.report).mode" Running))
    |}];
  return ()
;;

let%expect_test "a gate without a source is reported" =
  let%bind () =
    run ~overrides:"((toxicity_gate ()) (reference_guard ()))" (fun ~step ->
      step "started")
  in
  [%expect
    {|
    (starting(params((symbol BTC)(tick 1)(lot 0.00001)(order_size 0.001)(levels 1)(base_half_spread_bps 3)(level_spacing_bps 2)(skew_bps 4)(max_position 0.01)(max_notional 1500)(inventory_target 0)(requote_threshold_bps 1)(requote_interval_ms 1s)(order_ttl_ms 1m)(gamma 0.5)(vol_window 100)(max_vol_bps 10)(max_drawdown 50)(max_data_age_ms 5s)(flatten_slippage_bps 50)(max_actions_per_sec 100)(soft_max_position())(bump_budget 0)(toxicity_gate((widen_from 0.8)(pull_at 0.95)(max_extra_half_spread_bps 5)(skew_bps 2)(size_cut 0.5)(max_signal_age_ms 1m)))(reference_guard((band_bps 50)(grace_ms 2s)(max_jump_bps())(max_reference_age_ms 30s)(stale_reference Pull))))))
    reference_guard is set but no reference source is configured (-reference)
    toxicity_gate is set but no toxicity source is configured (-toxicity-bucket)
    (plausibility(event(Reference(Reference_missing(age_ms())))))
    (mode(from(Pulled No_market_data))(to_(Pulled(Reference_missing(age_ms())))))
    --- started
    stopping
    ((outcome.plausibility (("guard reference_missing" 1)))
     ("(outcome.report).mode" (Pulled (Reference_missing (age_ms ())))))
    |}];
  return ()
;;
