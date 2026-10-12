open! Core
open Exchange_core

type t =
  | Book of L2.t
  | Fill of Mm_core.Fill.t
  | Open_orders of Open_order.t list
  | Account of Account_view.t
[@@deriving sexp, compare, equal]

let apply strategy = function
  | Book book -> Mm_core.Strategy.on_book strategy book
  | Fill fill -> Mm_core.Strategy.on_fill strategy fill
  | Open_orders orders -> Mm_core.Strategy.on_open_orders strategy orders
  | Account account -> Mm_core.Strategy.on_account strategy account
;;
