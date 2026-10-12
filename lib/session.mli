(** One run of the strategy on a venue: [Mm_core.Live.Make (V)] with the extras the binary
    needs: tick-to-order latency in the outcome, and parameter reloads.

    A reload hands the new parameters to the running loop ([Mm_core.Live.update_params]):
    no restart and no cancel-all; the next tick requotes and the reconciler keeps the
    resting orders that still match. The venue is wrapped in {!Restartable_venue} so the
    shadow strategy and the strategy log see the loop's inputs. *)

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
    }
  [@@deriving sexp_of]

  (** The live report followed by a [tick-to-order] line (and [params reloads] and
      [shadow plans] lines after reloads and with a shadow). *)
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
      {!Strategy_log} (truncated at the start, a new [Params] line at each reload). *)
  val connect_and_run
    :  ?time_source:Time_source.t
    -> ?reload:unit Pipe.Reader.t
    -> ?shadow_params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> ?strategy_log:string
    -> V.config
    -> symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Outcome.t Or_error.t Deferred.t
end
