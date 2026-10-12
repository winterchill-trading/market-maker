(** An in-memory {!Mm_core.Venue.S} for tests: books are pushed by the test, places rest
    at their limit price, cancels remove orders. [config] is the venue itself, so a test
    keeps a handle on it while the live loop owns the connection. *)

open! Core
open! Async
open Exchange_core

type t

include Mm_core.Venue.S with type t := t and type config = t

val btc : Symbol.t
(** [place_delay] (default zero) delays every [place] answer on the time source. *)
val create : ?time_source:Time_source.t -> ?place_delay:Time_ns.Span.t -> unit -> t

(** A one-level book on {!btc}, stamped with the time source's now. Delivered to every open book reader and replayed to
    readers opened later. *)
val push_book : t -> bid:string -> ask:string -> unit

(** Fills the resting order with the highest bid (for [Buy]) or lowest ask. *)
val fill_best : t -> Side.t -> unit

val resting : t -> Open_order.t list
val reconnect : t -> unit
val closed : t -> bool
