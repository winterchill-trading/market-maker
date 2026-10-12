(** Follows an order log another process is writing: each read returns the complete lines
    appended since the previous one. *)

open! Core
open! Async

type t

val create : string -> t

(** The complete lines appended since the last read ([Lines []] while the file is missing);
    [Restart] when the file got shorter (a new run truncated it), after which reading
    starts again from the top. *)
val read_new : t -> [ `Lines of string list | `Restart ] Deferred.t

(** Folds the new lines into [status]; a restart starts from {!Order_log_status.empty}. *)
val update : t -> Order_log_status.t -> Order_log_status.t Deferred.t
