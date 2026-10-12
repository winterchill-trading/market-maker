(** A venue connection that outlives one [Mm_core.Live] loop, so the loop can be stopped
    and started again with new parameters on the same connection.

    The live loop owns its venue: it reads [fills] and [order_updates] (single consumer),
    subscribes to books, registers [on_reconnect] hooks and closes the venue on [stop]. In
    [Make (V)], [close] does nothing; {!next_loop} detaches the previous loop (closes the
    feeds and book readers handed to it and forgets its reconnect hooks) and {!shutdown}
    closes the underlying connection. *)

open! Core
open! Async

module Make (V : Mm_core.Venue.S) : sig
  include Mm_core.Venue.S with type config = V.config

  (** Detaches the readers and hooks handed out so far; the next [fills] and
      [order_updates] readers get everything from now on. *)
  val next_loop : t -> unit

  (** [f] sees every value the live loop hands to the strategy: books and fills as they
      arrive, open orders and account snapshots as their requests succeed. *)
  val add_observer : t -> (Strategy_input.t -> unit) -> unit

  (** [f] sees the order lifecycle: every place and cancel request before it is sent and
      its answer when it comes back, and every order update and fill the venue reports
      (including those that arrive between loops). *)
  val add_order_observer : t -> (Order_event.t -> unit) -> unit

  (** Closes the underlying connection. *)
  val shutdown : t -> unit Deferred.t
end
