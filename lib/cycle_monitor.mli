(** Watches the Async scheduler for long cycles: a cycle that runs longer than [warn_over]
    (default 20 ms) is logged as a warning, and cycles over [warn_over] and over
    [count_over] (default 50 ms) are counted. Every job in the process (book handling,
    planning, JSON decoding, the shadow and the logs) waits for the cycle in front of it,
    so a long cycle delays the next requote by that much. *)

open! Core
open! Async

module Stats : sig
  type t =
    { over_warn : int (** cycles longer than [warn_over] *)
    ; over_count : int (** cycles longer than [count_over] *)
    ; max : Time_ns.Span.t option (** the longest cycle over [warn_over] *)
    ; warn_over : Time_ns.Span.t
    ; count_over : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  (** [3 over 50ms, 12 over 20ms, max 74ms] *)
  val to_string_hum : t -> string
end

type t

val create : ?warn_over:Time_ns.Span.t -> ?count_over:Time_ns.Span.t -> unit -> t

(** Counts one cycle of that length (and logs it when over [warn_over]). {!start} feeds
    the scheduler's cycles here. *)
val record : t -> Time_ns.Span.t -> unit

(** Subscribes to the scheduler's cycles of at least [warn_over]
    ([Scheduler.long_cycles]). *)
val start : t -> unit

(** Stops counting; the scheduler's stream cannot be unsubscribed, later cycles are
    ignored. *)
val stop : t -> unit

val stats : t -> Stats.t
