open! Core
open! Async

module Outcome = struct
  type t =
    { report : Mm_core.Live.Report.t
    ; tick_to_order : Mm_core.Latency_histogram.Stats.t option
    }
  [@@deriving sexp_of]

  let to_string_hum t =
    sprintf
      "%s\ntick-to-order    %s"
      (Mm_core.Live.Report.to_string_hum t.report)
      (Option.value_map
         t.tick_to_order
         ~default:"-"
         ~f:Mm_core.Latency_histogram.Stats.to_string_hum)
  ;;
end

module Make (V : Mm_core.Venue.S) = struct
  module Live = Mm_core.Live.Make (V)

  let prepare ?time_source venue ~symbol ~params =
    let open Deferred.Or_error.Let_syntax in
    let%bind instrument = V.instrument venue symbol in
    let%bind mid = Live.first_mid ?time_source venue symbol in
    Deferred.return (Or_error.try_with_join (fun () -> params instrument ~mid))
  ;;

  let connect_and_run ?time_source config ~symbol ~params ~summary_interval ~stop =
    let%bind.Deferred.Or_error venue = V.connect config in
    let fail error =
      let%map () = V.close venue in
      Error error
    in
    match%bind prepare ?time_source venue ~symbol ~params with
    | Error error -> fail error
    | Ok params ->
      (match%bind
         Live.start ?time_source venue { Mm_core.Live.Config.params; summary_interval }
       with
       | Error error -> fail error
       | Ok live ->
         let%bind () = stop in
         let%map report = Live.stop live in
         Ok { Outcome.report; tick_to_order = Live.tick_to_order live })
  ;;
end
