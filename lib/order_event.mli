(** What happens to the account's orders, as the market maker sees it: the requests it
    sends, the venue's answers to them, and the venue's order updates and fills. The
    {!Order_log} writes them out with timestamps. *)

open! Core
open Exchange_core

type t =
  | Place of Order_request.t list (** a place request about to be sent *)
  | Placed of
      { requests : Order_request.t list
      ; result : Order_status.t list Or_error.t (** one status per request *)
      } (** the answer to a place request *)
  | Cancel of
      { symbol : Symbol.t
      ; order_ids : Order_id.t list
      } (** a cancel request about to be sent *)
  | Cancelled of
      { symbol : Symbol.t
      ; order_ids : Order_id.t list
      ; result : unit Or_error.t
      } (** the answer to a cancel request *)
  | Cancel_all of Symbol.t
  | Cancelled_all of
      { symbol : Symbol.t
      ; result : unit Or_error.t
      }
  | Update of Mm_core.Order_update.t (** from the venue's order feed *)
  | Fill of Mm_core.Fill.t (** from the venue's fill feed *)
[@@deriving sexp_of]
