open! Core
open! Async
open Market_maker

let%expect_test "counts and warns by length" =
  Session_helpers.print_logs ();
  let t = Cycle_monitor.create () in
  List.iter [ 5; 21; 49; 51; 80; 20 ] ~f:(fun ms ->
    Cycle_monitor.record t (Time_ns.Span.of_int_ms ms));
  let%bind () = Log.Global.flushed () in
  print_endline (Cycle_monitor.Stats.to_string_hum (Cycle_monitor.stats t));
  [%expect
    {|
    ("warning: long async cycle"(cycle 21ms)(over 20ms))
    ("warning: long async cycle"(cycle 49ms)(over 20ms))
    ("warning: long async cycle"(cycle 51ms)(over 20ms))
    ("warning: long async cycle"(cycle 80ms)(over 20ms))
    2 over 50ms, 4 over 20ms, max 80ms
    |}];
  return ()
;;

let%expect_test "a job that blocks the scheduler is a long cycle" =
  Log.Global.set_output [];
  let t = Cycle_monitor.create () in
  Cycle_monitor.start t;
  let%bind () = Scheduler.yield () in
  (* Blocks the whole cycle. *)
  ignore (Core_unix.nanosleep 0.06 : float);
  let%bind () = Scheduler.yield () in
  let%bind () = Scheduler.yield () in
  Cycle_monitor.stop t;
  let stats = Cycle_monitor.stats t in
  print_s
    [%message
      ""
        ~over_count:(stats.over_count >= 1 : bool)
        ~max_at_least_60ms:
          (Option.exists stats.max ~f:(fun longest ->
             Time_ns.Span.(longest >= of_int_ms 60))
           : bool)];
  [%expect {| ((over_count true) (max_at_least_60ms true)) |}];
  return ()
;;
