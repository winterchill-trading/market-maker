(** What happens to the account's orders, as the market maker sees it: the requests it
    sends, the venue's answers to them, and the venue's order updates and fills; and why
    quotes widen or go away: the plausibility events of the reference guard and the
    toxicity gate, and each toxicity measurement. The {!Order_log} writes them out with
    timestamps. *)

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
  | Plausibility of
      { symbol : Symbol.t
      ; event : Mm_core.Strategy.Event.t
      } (** the reference guard or the toxicity gate changed what it does *)
  | Toxicity of
      { symbol : Symbol.t
      ; signal : float
      ; imbalance : float
      ; decision : Mm_core.Toxicity_gate.Decision.t
      (** the gate's decision once the strategy took the measurement *)
      } (** a toxicity measurement given to the strategy *)
[@@deriving sexp_of]
