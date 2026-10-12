open! Core
open! Async

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

let update t status =
  match%map read_new t with
  | `Restart -> Order_log_status.empty
  | `Lines lines ->
    List.fold lines ~init:status ~f:(fun status line ->
      Order_log_status.add_row status (Order_log.parse_line line))
;;
