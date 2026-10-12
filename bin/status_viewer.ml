(* A terminal status viewer (Bonsai_term) over the order log a running market-maker writes
   with -order-log: resting orders, position, recent fills, ack latency. It tails the
   file, so it can run in another terminal, on another machine reading a copy, or after
   the run. A prototype: the order log is its only input. *)

open! Core
open! Async
open Market_maker

(* Reads the complete lines appended since [offset]; a shorter file (a new run truncated
   it) starts over. *)
module Tail = struct
  type t =
    { path : string
    ; mutable offset : int64
    ; mutable partial : string
    }

  let create path = { path; offset = 0L; partial = "" }

  let read_new t =
    In_thread.run (fun () ->
      match Core_unix.stat t.path with
      | exception Core_unix.Unix_error _ -> `Missing
      | stat when Int64.(stat.st_size < t.offset) -> `Truncated
      | _ ->
        In_channel.with_file t.path ~f:(fun ic ->
          In_channel.seek ic t.offset;
          let data = In_channel.input_all ic in
          `Data data))
    >>| function
    | `Missing -> `Lines []
    | `Truncated ->
      t.offset <- 0L;
      t.partial <- "";
      `Restart
    | `Data data ->
      t.offset <- Int64.(t.offset + of_int (String.length data));
      let text = t.partial ^ data in
      (match String.rsplit2 text ~on:'\n' with
       | None ->
         t.partial <- text;
         `Lines []
       | Some (complete, rest) ->
         t.partial <- rest;
         `Lines (String.split complete ~on:'\n'))
  ;;
end

let refresh tail status =
  match%map Tail.read_new tail with
  | `Restart -> Order_log_status.empty
  | `Lines lines ->
    List.fold lines ~init:status ~f:(fun status line ->
      Order_log_status.add_row status (Order_log.parse_line line))
;;

let now_ns () = Time_ns.to_int_ns_since_epoch (Time_ns.now ())

let app var ~exit ~dimensions (local_ _graph) =
  let open Bonsai_term in
  let view =
    Bonsai.map2
      (Bonsai.Expert.Var.value var)
      dimensions
      ~f:(fun (status, now_ns) (dimensions : Dimensions.t) ->
        let lines = Order_log_status.to_lines status ~now_ns in
        let title, rest =
          match lines with
          | [] -> "", []
          | title :: rest -> title, rest
        in
        View.vcat
          ([ View.text ~attrs:[ Attr.bold ] ("market-maker  " ^ title) ]
           @ List.map rest ~f:(fun line ->
             if String.is_prefix line ~prefix:" "
             then View.text line
             else View.text ~attrs:[ Attr.bold ] line)
           @ [ View.text ""; View.text "q to quit" ])
        |> View.crop ~b:(Int.max 0 (List.length lines + 2 - dimensions.height)))
  in
  let handler =
    Bonsai.return (fun (event : Event.t) ->
      match event with
      | Key_press { key = ASCII ('q' | 'Q'); mods = _ }
      | Key_press { key = ASCII ('c' | 'C'); mods = [ Ctrl ] } -> exit ()
      | _ -> Effect.Ignore)
  in
  ~view, ~handler
;;

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
       let tail = Tail.create path in
       let%bind status = refresh tail Order_log_status.empty in
       if once
       then (
         List.iter (Order_log_status.to_lines status ~now_ns:(now_ns ())) ~f:print_endline;
         Deferred.Or_error.ok_unit)
       else (
         let var = Bonsai.Expert.Var.create (status, now_ns ()) in
         let stop = Ivar.create () in
         Clock_ns.every'
           ~stop:(Ivar.read stop)
           (Time_ns.Span.of_int_ms refresh_ms)
           (fun () ->
              let status, _ = Bonsai.Expert.Var.get var in
              let%map status = refresh tail status in
              Bonsai.Expert.Var.set var (status, now_ns ()));
         let%map result = Bonsai_term.start_with_exit (app var) in
         Ivar.fill_if_empty stop ();
         result))
;;

let () = Command_unix.run command
