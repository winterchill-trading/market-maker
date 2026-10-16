(** The order lifecycle log ([-order-log FILE]): one CSV row per request sent, answer
    received, order update and fill, with the local time and, for what the venue reports,
    the venue's time. DuckDB reads it with [read_csv] (see [queries/fills_vs_trades.sql]).

    Columns, after a header line:

    - [local_ts]: nanoseconds since the epoch on the maker's clock, when the event was
      seen
    - [venue_ts]: the venue's timestamp of an [update] or [fill], empty otherwise
    - [venue], [symbol]
    - [event]: [place] (before a request is sent), [ack] (its answer), [cancel],
      [cancel_ack], [cancel_all], [cancel_all_ack], [update], [fill]; and for the
      plausibility checks [guard] (the reference guard), [gate] (the toxicity gate) and
      [toxicity] (a measurement given to the strategy)
    - [side] ([buy] or [sell]), [price], [size] ([remaining] for an [update])
    - [order_id], [client_order_id]
    - [status]: an [ack] is [resting], [filled], [rejected] or [error]; a [cancel_ack] or
      [cancel_all_ack] [ok] or [error]; an [update] the venue's status ([new],
      [partially_filled], [filled], [cancelled], [rejected]); a [fill] [maker] or [taker]
    - [trade_id], [fee]: of a [fill]
    - [detail]: the reject reason or error, the filled size of an [update] or an
      immediately filled [ack]

    Plausibility rows have no side, size or order: a [guard] row's [status] is [diverged],
    [reference_jumped], [reference_missing] or [resumed], its [price] the reference mid
    (when there is one) and its [detail] [divergence_bps=..], [held_ms=..], [venue_mid=..]
    or [from=..], [jump_bps=..]; a [gate] row's [status] is [widening], [pulled] or
    [cleared] with [signal=..]; a [toxicity] row's [status] is the gate's decision after
    the measurement ([normal], [widen] or [pull]) with [signal=..], [imbalance=..] and,
    while widening, [intensity=..], [extra_half_spread_bps=..], [shift_bps=..],
    [size_factor=..]. *)

open! Core
open! Async

type t

(** Where to write and the venue name to put in each row. *)
module Spec : sig
  type t =
    { path : string
    ; venue : string
    }
end

val header : string

(** The CSV rows of one event, without line endings. *)
val rows : venue:string -> local_ts:int -> Order_event.t -> string list

(** Splits one row back into its fields (RFC 4180 quoting, as the writer produces). *)
val parse_line : string -> string list

(** Writes the header. [now] stamps each event. *)
val create : Writer.t -> venue:string -> now:(unit -> int) -> t

val on_event : t -> Order_event.t -> unit
