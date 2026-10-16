(** One run of the strategy on a venue: [Mm_core.Live.Make (V)] with the extras the binary
    needs: tick-to-order latency in the outcome, parameter reloads, and the inputs of the
    reference guard and the toxicity gate.

    A reload hands the new parameters to the running loop ([Mm_core.Live.update_params]):
    no restart and no cancel-all; the next tick requotes and the reconciler keeps the
    resting orders that still match. The venue is wrapped in {!Restartable_venue} so the
    shadow strategy and the strategy log see the loop's inputs: they attach in the
    [on_venue] hook of [Mm_core.Live.Make (V).connect_and_start], before the loop starts,
    and start the same action rate grace period as the loop on every venue reconnect
    ([Mm_core.Live.Make (V).on_resync]). *)

open! Core
open! Async
open Exchange_core

module Outcome : sig
  type t =
    { report : Mm_core.Live.Report.t
    ; tick_to_order : Mm_core.Latency_histogram.Stats.t option
    (** from a book update to the plan it led to being sent; [None] when no plan followed
        a book update *)
    ; reloads : int (** parameter changes applied *)
    ; shadow : Shadow.Stats.t option (** with [shadow_params] *)
    ; cycles : Cycle_monitor.Stats.t option (** with [cycle_monitor] *)
    ; plausibility : (string * int) list
    (** plausibility events by kind ([guard diverged], [gate pulled], ...), sorted *)
    }
  [@@deriving sexp_of]

  (** The live report, an [async cycles] line with a cycle monitor, a [tick-to-order]
      line, [params reloads] and [shadow plans] lines after reloads and with a shadow, and
      a [plausibility] line once the guard or the gate reported something. *)
  val to_string_hum : t -> string
end

module Make (V : Mm_core.Venue.S) : sig
  (** Connects, fetches the instrument and its first mid, builds the parameters with
      [params], quotes until [stop], then cancels everything and closes the venue (on
      every path), as [Mm_core.Live.Make (V).connect_and_run].

      Every value read from [reload] calls [params] again (with the same instrument and
      first mid). An error is logged and the current parameters stay; parameters equal to
      the current ones are ignored; others go to the running loop. When the loop rejects
      them (another symbol, invalid values) the error is logged and the current parameters
      stay.

      With [shadow_params], a {!Shadow} strategy runs on the same inputs with those
      parameters (built like [params], and read again on every reload) and its differing
      plans are logged; an error at start fails the run, on reload it keeps the current
      shadow parameters.

      With [strategy_log], every strategy input and plan goes to that file as a
      {!Strategy_log} (truncated before connecting, an [Update_params] line at each
      reload, a [Resync] line at each venue reconnect).

      With [order_log], every place and cancel request, its answer, and every order update
      and fill goes to that file as an {!Order_log} (truncated before connecting, closed
      after the final cancel-all), and so do the plausibility events and the toxicity
      measurements.

      [reference] (mids from a {!Reference_source}) and [toxicity] (from a
      {!Toxicity_source}) are read once the loop has started, each value going to
      [Mm_core.Live.on_reference] or [on_toxicity] and, stamped with the same time, to the
      shadow strategy and the strategy log. Both are closed on stop. The parameters'
      [reference_guard] and [toxicity_gate] act on them; either set without its source is
      logged as an error at start and at every reload that keeps it. *)
  val connect_and_run
    :  ?time_source:Time_source.t
    -> ?reload:unit Pipe.Reader.t
    -> ?shadow_params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> ?strategy_log:string
    -> ?order_log:Order_log.Spec.t
    -> ?cycle_monitor:Cycle_monitor.t
    -> ?reference:Price.t Pipe.Reader.t
    -> ?toxicity:Toxicity_source.Signal.t Pipe.Reader.t
    -> V.config
    -> symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Outcome.t Or_error.t Deferred.t
end
