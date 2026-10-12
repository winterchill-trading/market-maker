(** A running summary of an {!Order_log}, for the status viewer: resting orders, position
    and volume from fills, request to answer latency, and counts per event. It is folded
    from the log's rows ({!Order_log.parse_line}), so it works on a file another process
    is writing. *)

open! Core
open Exchange_core

module Resting : sig
  type t =
    { side : Side.t
    ; price : Price.t
    ; size : Size.t
    ; since_ns : int (** local time of the ack *)
    }
  [@@deriving sexp_of]
end

module Fill : sig
  type t =
    { local_ns : int
    ; side : Side.t
    ; price : Price.t
    ; size : Size.t
    ; maker : bool
    }
  [@@deriving sexp_of]
end

type t [@@deriving sexp_of]

val empty : t

(** Applies one row (the header and malformed rows are counted and skipped). *)
val add_row : t -> string list -> t

val venue : t -> string option
val symbol : t -> string option

(** Resting orders by order id: acked [resting], until a final update, a fill of the whole
    order or a successful cancel. *)
val resting : t -> Resting.t String.Map.t

(** Net position from the fills in the log (positive long). *)
val position : t -> Size.t

val volume : t -> Usd.t
val fees : t -> Usd.t

(** The latest fills, newest first (at most 8). *)
val recent_fills : t -> Fill.t list

(** Latency from a [place] row to its [ack], over the latest 200 acks:
    [(count, median, max)] in nanoseconds. *)
val ack_latency : t -> (int * int * int) option

val count : t -> string -> int
val last_ns : t -> int option

(** A plain text rendering, one line per element; [now_ns] dates the latest row. *)
val to_lines : t -> now_ns:int -> string list
