(** What the live loop feeds [Mm_core.Strategy] between ticks, as one value. *)

open! Core
open Exchange_core

type t =
  | Book of L2.t
  | Fill of Mm_core.Fill.t
  | Open_orders of Open_order.t list
  | Account of Account_view.t
[@@deriving sexp, compare, equal]

(** The matching [Strategy.on_*] handler. *)
val apply : Mm_core.Strategy.t -> t -> Mm_core.Strategy.t
