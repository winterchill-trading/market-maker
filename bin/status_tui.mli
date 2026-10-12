(** The terminal view of the status viewer: [status_tui.bonsai.ml] with Bonsai_term,
    [status_tui.fallback.ml] where bonsai_term is not installed (dune [select]). *)

open! Core
open! Async
open Market_maker

(** Whether this build has the terminal view. *)
val available : bool

(** Shows [status] and folds in the tail's new rows every [refresh] until [q] or Ctrl-C. *)
val run
  :  Order_log_tail.t
  -> Order_log_status.t
  -> refresh:Time_ns.Span.t
  -> unit Or_error.t Deferred.t
