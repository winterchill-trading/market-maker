(* A terminal status viewer over the order log a running market-maker writes with
   -order-log: resting orders, position, recent fills, ack latency. It tails the file, so
   it can run in another terminal, or after the run. A prototype: the order log is its
   only input. *)

open! Core
open! Async
open Market_maker

let command =
  Command.async_or_error
    ~summary:"Terminal status of a market-maker run, from its -order-log file"
    (let%map_open.Command path = anon ("ORDER_LOG" %: Filename_unix.arg_type)
     and once = flag "-once" no_arg ~doc:" print the status once as text and exit"
     and refresh_ms =
       flag
         "-refresh-ms"
         (optional_with_default 250 int)
         ~doc:"MS how often to read new rows (default 250)"
     in
     fun () ->
       let tail = Order_log_tail.create path in
       let%bind status = Order_log_tail.update tail Order_log_status.empty in
       if once || not Status_tui.available
       then (
         let now_ns = Time_ns.to_int_ns_since_epoch (Time_ns.now ()) in
         List.iter (Order_log_status.to_lines status ~now_ns) ~f:print_endline;
         if once
         then Deferred.Or_error.ok_unit
         else Status_tui.run tail status ~refresh:(Time_ns.Span.of_int_ms refresh_ms))
       else Status_tui.run tail status ~refresh:(Time_ns.Span.of_int_ms refresh_ms))
;;

let () = Command_unix.run command
