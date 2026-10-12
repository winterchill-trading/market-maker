(** Drives {!Market_maker.Session} over {!Fake_venue} on a synthetic clock. *)

open! Core
open! Async

val start_time : Time_ns.t

(** Sends [Log.Global] messages to stdout, without times or levels. *)
val print_logs : unit -> unit

(** Advances the clock by [span] in 10 ms steps, running every job in between. *)
val advance : Time_source.Read_write.t -> Time_ns.Span.t -> unit Deferred.t

(** Advances the clock in 100 ms steps until [d] is determined (at most a minute). *)
val advance_until : Time_source.Read_write.t -> 'a Deferred.t -> 'a Deferred.t

(** Polls [f] on the wall clock (every millisecond, running every job in between) until it
    holds; raises after 10 seconds. For work outside the synthetic clock, such as file IO
    in threads. *)
val wait_until : what:string -> (unit -> bool) -> unit Deferred.t
