(** Drives {!Market_maker.Session} over {!Fake_venue} on a synthetic clock. *)

open! Core
open! Async

val start_time : Time_ns.t

(** Advances the clock by [span] in 10 ms steps, running every job in between. *)
val advance : Time_source.Read_write.t -> Time_ns.Span.t -> unit Deferred.t

(** Advances the clock in 100 ms steps until [d] is determined (at most a minute). *)
val advance_until : Time_source.Read_write.t -> 'a Deferred.t -> 'a Deferred.t
