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

(** Swaps the parameters of both strategies in place ([Mm_core.Strategy.update_params]),
    as the live loop does on a reload: market state, inventory and resting orders carry
    on, and so do the counts. Errors, changing nothing, if either is rejected. *)
val update_params
  :  t
  -> live:Mm_core.Params.t
  -> shadow:Mm_core.Params.t
  -> unit Or_error.t

(** Feeds [input] to both strategies, ticks both at [now] (nanoseconds since the epoch),
    and calls [on_difference] (default: log at info level) when their plans differ. *)
val on_input
  :  ?on_difference:(live:Plan.t -> shadow:Plan.t -> unit)
  -> t
  -> Strategy_input.t
  -> now:int
  -> unit

(** Starts the action rate grace period of both strategies at [now]
    ([Mm_core.Strategy.on_resync]), as the live loop does on a venue reconnect, so a
    requote burst after the resync does not halt them when it does not halt the live one. *)
val on_resync : t -> now:int -> unit

(** The mode of the mirror of the live strategy. *)
val live_mode : t -> Mm_core.Strategy.Mode.t

(** The mode of the shadow strategy. *)
val shadow_mode : t -> Mm_core.Strategy.Mode.t

val stats : t -> Stats.t
