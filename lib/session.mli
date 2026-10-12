(** One run of the strategy on a venue: [Mm_core.Live.Make (V)] with the extras the binary
    reports, such as tick-to-order latency. *)

open! Core
open! Async
open Exchange_core

module Outcome : sig
  type t =
    { report : Mm_core.Live.Report.t
    ; tick_to_order : Mm_core.Latency_histogram.Stats.t option
    (** from a book update to the plan it led to being sent; [None] when no plan followed
        a book update *)
    }
  [@@deriving sexp_of]

  (** The live report followed by a [tick-to-order] line. *)
  val to_string_hum : t -> string
end

module Make (V : Mm_core.Venue.S) : sig
  (** Connects, fetches the instrument and its first mid, builds the parameters with
      [params], quotes until [stop], then cancels everything and closes the venue (on
      every path), as [Mm_core.Live.Make (V).connect_and_run]. *)
  val connect_and_run
    :  ?time_source:Time_source.t
    -> V.config
    -> symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Outcome.t Or_error.t Deferred.t
end
