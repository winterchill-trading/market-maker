(** Venue selection: builds the client configuration of Hyperliquid, Binance or Bybit (or
    their simulators) from command-line choices and the environment, and hides the venue
    behind a common {!RUNNER} interface over {!Session.Make}. *)

open! Core
open! Async
open Exchange_core

module Venue_choice : sig
  type t =
    | Hyperliquid
    | Binance
    | Bybit
  [@@deriving sexp, compare, equal, enumerate]

  (** ["hyperliquid"], ["binance"], ["bybit"]. *)
  val to_string : t -> string

  (** Case-insensitive; also accepts ["hl"]. *)
  val of_string : string -> t

  val arg_type : t Command.Arg_type.t

  (** ["BTC"] on Hyperliquid, ["BTCUSDT"] on Binance and Bybit. *)
  val default_symbol : t -> Symbol.t

  (** The local simulator's default port: 3000, 3300 and 3400. *)
  val default_port : t -> int
end

module Network : sig
  type t =
    | Local
    | Testnet
    | Mainnet
  [@@deriving sexp, compare, equal, enumerate]

  val to_string : t -> string
  val arg_type : t Command.Arg_type.t
end

(** A venue with its connection settings bound: everything the binary needs to run the
    strategy, whichever venue it is. *)
module type RUNNER = sig
  val venue : Venue_choice.t

  (** Where requests go, for logging (credentials are left out). *)
  val endpoint : string

  (** The venue's minimum order value on [symbol], when it publishes one: Binance's
      [MIN_NOTIONAL] filter, Bybit's [minNotionalValue], Hyperliquid's fixed 10 USD. *)
  val min_notional : Symbol.t -> Usd.t option Or_error.t Deferred.t

  (** [Session.Make (V).connect_and_run] with the bound configuration. *)
  val connect_and_run
    :  ?time_source:Time_source.t
    -> ?reload:unit Pipe.Reader.t
    -> ?shadow_params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> ?strategy_log:string
    -> symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Session.Outcome.t Or_error.t Deferred.t
end

(** Builds the configuration and picks the adapter.

    - [base_url] overrides the network's REST root (websocket URLs are derived from it).
    - Hyperliquid signs exchange requests when [HL_PRIVATE_KEY] holds a key (through
      [Hl_mm.Hl_venue.Trading]; the signing domain is testnet unless the REST root is
      [api.hyperliquid.xyz]). It acts for [address], else [HL_ADDRESS], else the key's
      address, else (local only) a fixed simulator address. Without a key requests are
      unsigned (the simulator's [X-Address] convention).
    - Signing for Hyperliquid mainnet ([network = Mainnet] or a mainnet REST root) is
      refused unless [allow_mainnet] (default [false], the binary's
      [-i-understand-mainnet]). No default points a signed run at mainnet: the binary's
      network defaults to [Local].
    - Binance reads [BINANCE_API_KEY] and [BINANCE_API_SECRET], Bybit [BYBIT_API_KEY] and
      [BYBIT_API_SECRET]. Testnet and mainnet need both; locally the key defaults to
      ["market-maker"] (the simulators use it as the account) and the secret is optional.

    [getenv] defaults to [Sys.getenv]. *)
val runner
  :  ?base_url:Uri.t
  -> ?address:string
  -> ?allow_mainnet:bool
  -> ?getenv:(string -> string option)
  -> Venue_choice.t
  -> network:Network.t
  -> (module RUNNER) Or_error.t
