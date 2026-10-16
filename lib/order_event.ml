open! Core
open Exchange_core

type t =
  | Place of Order_request.t list
  | Placed of
      { requests : Order_request.t list
      ; result : Order_status.t list Or_error.t
      }
  | Cancel of
      { symbol : Symbol.t
      ; order_ids : Order_id.t list
      }
  | Cancelled of
      { symbol : Symbol.t
      ; order_ids : Order_id.t list
      ; result : unit Or_error.t
      }
  | Cancel_all of Symbol.t
  | Cancelled_all of
      { symbol : Symbol.t
      ; result : unit Or_error.t
      }
  | Update of Mm_core.Order_update.t
  | Fill of Mm_core.Fill.t
  | Plausibility of
      { symbol : Symbol.t
      ; event : Mm_core.Strategy.Event.t
      }
  | Toxicity of
      { symbol : Symbol.t
      ; signal : float
      ; imbalance : float
      ; decision : Mm_core.Toxicity_gate.Decision.t
      }
[@@deriving sexp_of]
