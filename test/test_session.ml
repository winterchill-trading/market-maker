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
