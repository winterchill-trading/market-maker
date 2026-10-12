(** A debug log of the strategy: every input and every tick with its plan, one sexp per
    line, so that a run can be replayed through [Mm_core.Strategy] offline.

    The log is written by a mirror strategy with the live parameters, fed the inputs of
    the live one ({!Restartable_venue.add_observer}) and ticked after each input. The live
    loop coalesces ticks and runs them on its sequencer, so its plans can come at slightly
    different moments; the logged plans are what the strategy decides for exactly the
    logged inputs and times, which is what a replay reproduces.

    {v
(Params ((symbol BTC) (tick 1) ...))
(Input (Book ((symbol BTC) (time 1800000000000000000) (bids ...) (asks ...))))
(Tick (now 1800000000000000000) (plan ((Place ...) ...)))
    v} *)

open! Core
open! Async

module Event : sig
  type t =
    | Params of Mm_core.Params.t (** a new strategy (the start of the log) *)
    | Update_params of Mm_core.Params.t
    (** a reload: [Mm_core.Strategy.update_params] on the running strategy *)
    | Input of Strategy_input.t
    | Resync of { now : int }
    (** a venue reconnect: [Mm_core.Strategy.on_resync] at [now] (nanoseconds since the
        epoch), which starts the action rate grace period *)
    | Tick of
        { now : int (** nanoseconds since the epoch *)
        ; plan : Mm_core.Action.t list
        }
  [@@deriving sexp, compare, equal]
end

type t

(** Creates (truncates) the file and writes the [Params] line. *)
val create : string -> params:Mm_core.Params.t -> t Deferred.t

(** As [create], on an open writer (the log owns it from here: [close] closes it). *)
val of_file_writer : Writer.t -> params:Mm_core.Params.t -> t

(** For tests and other sinks: [write] receives every event. *)
val of_writer : (Event.t -> unit) -> params:Mm_core.Params.t -> t

(** Logs [input], feeds it to the mirror, ticks at [now] and logs the plan. *)
val on_input : t -> Strategy_input.t -> now:int -> unit

(** Starts the mirror's action rate grace period at [now] as the live loop does on a venue
    reconnect ([Mm_core.Strategy.on_resync]) and logs a [Resync] line, so the requote
    burst that follows replays to the same plans. *)
val on_resync : t -> now:int -> unit

(** The mirror's mode. *)
val mode : t -> Mm_core.Strategy.Mode.t

(** Swaps the mirror's parameters as the live loop does on a reload
    ([Mm_core.Strategy.update_params]) and logs an [Update_params] line. Errors, logging
    nothing, when the strategy rejects them. *)
val update_params : t -> Mm_core.Params.t -> unit Or_error.t

(** Flushes and closes the file. *)
val close : t -> unit Deferred.t

val load : string -> Event.t list Or_error.t Deferred.t

module Replay : sig
  type mismatch =
    { line : int (** 1-based line of the [Tick] in the log *)
    ; now : int
    ; logged : Mm_core.Action.t list
    ; replayed : Mm_core.Action.t list
    }
  [@@deriving sexp_of]

  type t =
    { ticks : int
    ; plans : int (** ticks with a non-empty plan *)
    ; mismatches : mismatch list
    }
  [@@deriving sexp_of]

  (** Runs the events through a fresh [Mm_core.Strategy] (a new one at every [Params],
      updated in place at every [Update_params], resynced at every [Resync]) and compares
      each tick's plan with the logged one. Fails when the log does not start with
      [Params]. *)
  val run : Event.t list -> t Or_error.t
end
