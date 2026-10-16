(** Reference mids for the reference guard ([Mm_core.Reference_guard]): an independent
    price the venue's mid is checked against.

    - [Anchor]: the simulator's own reference, when it runs anchored (hl-sim, binance-sim
      and bybit-sim with [-anchor]). The simulator's anchor status is polled
      ([GET /status] on hl-sim, [GET /sim/anchor] on the others) and the anchor of the
      quoted symbol gives its [reference_price] while it is fresh. A stale anchor gives
      nothing, so the guard sees the reference age.
    - [Feed]: the mid of another venue's best bid and offer, from its public read-only
      feed (Hyperliquid, Binance or Bybit), against [base_url] or the venue's mainnet. A
      mid is passed on every top-of-book change, so a quiet market also ages the
      reference: set [max_reference_age_ms] above the reference's usual quiet spells. *)

open! Core
open! Async
open Exchange_core

module Spec : sig
  type t =
    | Anchor
    | Feed of
        { venue : string (** [hyperliquid], [binance] or [bybit] *)
        ; symbol : string (** the venue's name, e.g. [BTC] or [BTCUSDT] *)
        ; base_url : Uri.t option (** REST root; the venue's mainnet when absent *)
        }
  [@@deriving sexp_of, equal]

  (** ["anchor"], or ["<venue>:<symbol>"] with an optional ["@<base url>"], e.g.
      ["binance:BTCUSDT"] or ["hyperliquid:BTC@http://127.0.0.1:3000"]. *)
  val of_string : string -> t Or_error.t

  val to_string : t -> string
  val arg_type : t Command.Arg_type.t
end

(** One anchor's entry in a simulator's anchor status, whichever simulator served it. *)
module Anchor_status : sig
  type t =
    { symbol : string (** the simulated symbol *)
    ; fresh : bool
    ; reference_price : Price.t option
    }
  [@@deriving sexp_of, equal]

  (** Reads hl-sim's [/status] object (its [anchors] list) or the list of binance-sim's
      and bybit-sim's [/sim/anchor]. Entries it cannot read are left out. *)
  val of_json : Yojson.Safe.t -> t list

  (** The reference price of [symbol]'s anchor when it is fresh. *)
  val reference : t list -> symbol:string -> Price.t option
end

(** Polls [status_url] every [interval] (default 500ms) and passes [symbol]'s fresh
    reference price on each poll. Request and parse errors are logged at debug level and
    pass nothing. Closing the result stops polling. *)
val of_anchor_status
  :  ?interval:Time_ns.Span.t
  -> ?time_source:Time_source.t
  -> status_url:Uri.t
  -> symbol:string
  -> unit
  -> Price.t Pipe.Reader.t

(** Mids of the feed's best bid and offer (both sides present). Its other pipes are closed
    at once; closing the result closes the feed. *)
val of_feed : Market_data.Feed.t -> Price.t Pipe.Reader.t
