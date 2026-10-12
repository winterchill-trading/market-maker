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
    | Params of Mm_core.Params.t (** a new strategy: the start, or a reload *)
    | Input of Strategy_input.t
    | Tick of
        { now : int (** nanoseconds since the epoch *)
        ; plan : Mm_core.Action.t list
        }
  [@@deriving sexp, compare, equal]
end

type t

(** Creates (truncates) the file and writes the [Params] line. *)
val create : string -> params:Mm_core.Params.t -> t Deferred.t

(** For tests and other sinks: [write] receives every event. *)
val of_writer : (Event.t -> unit) -> params:Mm_core.Params.t -> t

(** Logs [input], feeds it to the mirror, ticks at [now] and logs the plan. *)
val on_input : t -> Strategy_input.t -> now:int -> unit

(** Starts a new mirror with [params] (after a reload) and logs a [Params] line. *)
val restart : t -> params:Mm_core.Params.t -> unit

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

  (** Runs the events through a fresh [Mm_core.Strategy] (a new one at every [Params]) and
      compares each tick's plan with the logged one. Fails when the log does not start
      with [Params]. *)
  val run : Event.t list -> t Or_error.t
end
