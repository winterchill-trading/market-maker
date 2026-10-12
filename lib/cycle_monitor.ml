open! Core
open! Async

module Stats = struct
  type t =
    { over_warn : int
    ; over_count : int
    ; max : Time_ns.Span.t option
    ; warn_over : Time_ns.Span.t
    ; count_over : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  let span_hum span = Time_ns.Span.to_string_hum ~decimals:0 span

  let to_string_hum t =
    sprintf
      "%d over %s, %d over %s, max %s"
      t.over_count
      (span_hum t.count_over)
      t.over_warn
      (span_hum t.warn_over)
      (Option.value_map t.max ~default:"-" ~f:span_hum)
  ;;
end

type t =
  { warn_over : Time_ns.Span.t
  ; count_over : Time_ns.Span.t
  ; mutable over_warn : int
  ; mutable over_count : int
  ; mutable max : Time_ns.Span.t option
  ; mutable running : bool
  }

let create
  ?(warn_over = Time_ns.Span.of_int_ms 20)
  ?(count_over = Time_ns.Span.of_int_ms 50)
  ()
  =
  { warn_over; count_over; over_warn = 0; over_count = 0; max = None; running = false }
;;

let record t span =
  if Time_ns.Span.(span > t.warn_over)
  then (
    t.over_warn <- t.over_warn + 1;
    if Time_ns.Span.(span > t.count_over) then t.over_count <- t.over_count + 1;
    t.max
    <- Some
         (match t.max with
          | None -> span
          | Some max -> Time_ns.Span.max max span);
    Log.Global.info_s
      [%message
        "warning: long async cycle"
          ~cycle:(Stats.span_hum span : string)
          ~over:(Stats.span_hum t.warn_over : string)])
;;

let start t =
  if not t.running
  then (
    t.running <- true;
    Stream.iter (Scheduler.long_cycles ~at_least:t.warn_over) ~f:(fun span ->
      if t.running then record t span))
;;

let stop t = t.running <- false

let stats t =
  { Stats.over_warn = t.over_warn
  ; over_count = t.over_count
  ; max = t.max
  ; warn_over = t.warn_over
  ; count_over = t.count_over
  }
;;
