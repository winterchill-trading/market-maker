(** A shadow strategy: a second [Mm_core.Strategy] with other parameters, fed the same
    inputs as the live one, whose plans are compared with the plans of a mirror of the
    live strategy and logged when they differ. Nothing the shadow plans is sent.

    Both strategies tick after every input, at the same time. The mirror runs the live
    parameters on the same inputs, so a difference comes from the parameters alone, not
    from timing; the live loop itself coalesces ticks, so its plans can come at slightly
    different moments than the mirror's. Both see the live orders in their open-orders
    snapshots. *)

open! Core
open Exchange_core

module Plan : sig
  (** A plan without client order ids (they embed a generation counter, which differs as
      soon as one strategy places and the other does not). *)
  type t =
    { cancels : Order_id.t list
    ; keeps : Order_id.t list
    ; places : Order_request.t list
    }
  [@@deriving sexp_of, compare, equal]

  val of_actions : Mm_core.Action.t list -> t

  (** ["cancel 2, keep 4, place [buy 0.001@99970 sell 0.001@100030]"]. *)
  val to_string_hum : t -> string
end

module Stats : sig
  type t =
    { plans : int (** ticks where at least one of the two planned something *)
    ; differing : int
    }
  [@@deriving sexp_of]
end

type t

val create : live:Mm_core.Params.t -> shadow:Mm_core.Params.t -> t

(** Starts both strategies again from scratch (after a parameter reload); the counts carry
    on. *)
val restart : t -> live:Mm_core.Params.t -> shadow:Mm_core.Params.t -> unit

(** Feeds [input] to both strategies, ticks both at [now] (nanoseconds since the epoch),
    and calls [on_difference] (default: log at info level) when their plans differ. *)
val on_input
  :  ?on_difference:(live:Plan.t -> shadow:Plan.t -> unit)
  -> t
  -> Strategy_input.t
  -> now:int
  -> unit

val stats : t -> Stats.t
