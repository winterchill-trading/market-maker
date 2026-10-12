open! Core
open! Async

let start_time = Time_ns.of_int_ns_since_epoch 1_800_000_000_000_000_000

let print_logs () =
  Log.Global.set_output
    [ Log.Output.create
        ~flush:(fun () -> return ())
        (fun messages ->
          Queue.iter messages ~f:(fun m -> print_endline (Log.Message.message m));
          return ())
    ]
;;

let advance time_source span =
  let step = Time_ns.Span.of_int_ms 10 in
  let rec loop left =
    if Time_ns.Span.(left <= zero)
    then return ()
    else (
      let%bind () = Time_source.advance_by_alarms_by time_source step in
      let%bind () = Scheduler.yield_until_no_jobs_remain () in
      loop Time_ns.Span.(left - step))
  in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  loop span
;;

let advance_until time_source d =
  let rec loop n =
    match Deferred.peek d with
    | Some x -> return x
    | None when n = 0 -> raise_s [%message "still not determined after a minute"]
    | None ->
      let%bind () = advance time_source (Time_ns.Span.of_int_ms 100) in
      loop (n - 1)
  in
  loop 600
;;

let wait_until ~what f =
  let rec loop n =
    let%bind () = Scheduler.yield_until_no_jobs_remain () in
    if f ()
    then return ()
    else if n = 0
    then raise_s [%message "timed out waiting" what]
    else (
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
      loop (n - 1))
  in
  loop 10_000
;;
