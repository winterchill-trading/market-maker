(** What the live loop feeds [Mm_core.Strategy] between ticks, as one value. *)

open! Core
open Exchange_core

type t =
  | Book of L2.t
  | Fill of Mm_core.Fill.t
  | Open_orders of Open_order.t list
  | Account of Account_view.t
  | Reference of
      { time : int (** nanoseconds since the epoch, when the loop took it *)
      ; mid : Price.t
      } (** a reference mid for the reference guard *)
  | Toxicity of
      { time : int
      ; signal : float
      ; imbalance : float
      } (** a toxicity measurement for the toxicity gate *)
[@@deriving sexp, compare, equal]

(** The matching [Strategy.on_*] handler. *)
val apply : Mm_core.Strategy.t -> t -> Mm_core.Strategy.t
