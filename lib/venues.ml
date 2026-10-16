open! Core
open! Async
open Exchange_core

module Venue_choice = struct
  type t =
    | Hyperliquid
    | Binance
    | Bybit
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Hyperliquid -> "hyperliquid"
    | Binance -> "binance"
    | Bybit -> "bybit"
  ;;

  let of_string s =
    match String.lowercase s with
    | "hyperliquid" | "hl" -> Hyperliquid
    | "binance" -> Binance
    | "bybit" -> Bybit
    | _ -> raise_s [%message "unknown venue, expected hyperliquid, binance or bybit" s]
  ;;

  let arg_type =
    Command.Arg_type.create of_string ~complete:(fun _ ~part ->
      List.filter_map all ~f:(fun t ->
        let s = to_string t in
        Option.some_if (String.is_prefix s ~prefix:part) s))
  ;;

  let default_symbol = function
    | Hyperliquid -> Symbol.of_string "BTC"
    | Binance | Bybit -> Symbol.of_string "BTCUSDT"
  ;;

  let default_port = function
    | Hyperliquid -> 3000
    | Binance -> 3300
    | Bybit -> 3400
  ;;
end

module Network = struct
  type t =
    | Local
    | Testnet
    | Mainnet
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Local -> "local"
    | Testnet -> "testnet"
    | Mainnet -> "mainnet"
  ;;

  let arg_type =
    Command.Arg_type.create (fun s ->
      match String.lowercase s with
      | "local" -> Local
      | "testnet" -> Testnet
      | "mainnet" -> Mainnet
      | _ -> raise_s [%message "unknown network, expected local, testnet or mainnet" s])
  ;;
end

module type RUNNER = sig
  val venue : Venue_choice.t
  val endpoint : string
  val min_notional : Symbol.t -> Usd.t option Or_error.t Deferred.t

  val connect_and_run
    :  ?time_source:Time_source.t
    -> ?reload:unit Pipe.Reader.t
    -> ?shadow_params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> ?strategy_log:string
    -> ?order_log:string
    -> ?cycle_monitor:Cycle_monitor.t
    -> ?reference:Reference_source.Spec.t
    -> ?toxicity:Toxicity_source.Config.t
    -> symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Session.Outcome.t Or_error.t Deferred.t
end

(* "mm" in ASCII, as in hl-mm. *)
let simulator_address = "0x0000000000000000000000000000000000006d6d"
let local_api_key = "market-maker"
let hyperliquid_min_notional = Usd.of_int 10

let order_log_spec ~venue order_log =
  Option.map order_log ~f:(fun path ->
    { Order_log.Spec.path; venue = Venue_choice.to_string venue })
;;

(* Public feeds: [Feed] references (another venue, its mainnet by default) and the venue's
   own trades for the toxicity signal. A first connection that fails raises in the
   clients; it becomes an error here. *)
let public_feed ~venue ~base_url ~symbol ~streams =
  Monitor.try_with_or_error (fun () ->
    match venue with
    | "hyperliquid" ->
      let config =
        match base_url with
        | Some base_url -> Hl_client.Config.create ~base_url ()
        | None -> Hl_client.Config.mainnet ()
      in
      Hl_client.Live_feed.create config ~symbols:[ symbol ] ~streams
    | "binance" ->
      let config =
        match base_url with
        | Some base_url -> Binance_client.Config.Read_only.create ~base_url ()
        | None -> Binance_client.Config.Read_only.mainnet ()
      in
      Binance_client.Live_feed.create config ~symbols:[ symbol ] ~streams
    | "bybit" ->
      let config =
        match base_url with
        | Some base_url -> Bybit_client.Config.create ~base_url ()
        | None -> Bybit_client.Config.mainnet ()
      in
      Bybit_client.Live_feed.create config ~symbols:[ symbol ] ~streams
    | venue -> raise_s [%message "no public feed for this venue" venue])
;;

(* Opens the reference and toxicity sources of a run on [venue] at [base_url] (its REST
   root). Errors close what was already opened. *)
let open_sources ~venue ~base_url ~symbol ?reference ?toxicity () =
  let open Deferred.Or_error.Let_syntax in
  let symbol = Symbol.to_string symbol in
  let%bind reference =
    match (reference : Reference_source.Spec.t option) with
    | None -> return None
    | Some Anchor ->
      let path =
        match (venue : Venue_choice.t) with
        | Hyperliquid -> "/status"
        | Binance | Bybit -> "/sim/anchor"
      in
      return
        (Some
           (Reference_source.of_anchor_status
              ~status_url:(Uri.with_path base_url path)
              ~symbol
              ()))
    | Some (Feed { venue; symbol; base_url }) ->
      let%map feed = public_feed ~venue ~base_url ~symbol ~streams:[ Bbo ] in
      Some (Reference_source.of_feed feed)
  in
  match toxicity with
  | None -> return (reference, None)
  | Some config ->
    (match%bind.Deferred
       public_feed
         ~venue:(Venue_choice.to_string venue)
         ~base_url:(Some base_url)
         ~symbol
         ~streams:[ Trades ]
     with
     | Ok feed -> return (reference, Some (Toxicity_source.of_feed config feed))
     | Error error ->
       Option.iter reference ~f:Pipe.close_read;
       Deferred.Or_error.fail error)
;;

(* [open_sources], then [run] with them; both are closed when [run] returns. *)
let with_sources ~venue ~base_url ~symbol ?reference ?toxicity run =
  match%bind open_sources ~venue ~base_url ~symbol ?reference ?toxicity () with
  | Error error -> Deferred.Or_error.fail (Error.tag error ~tag:"reference or toxicity")
  | Ok (reference, toxicity) ->
    let%map result = run ?reference ?toxicity () in
    Option.iter reference ~f:Pipe.close_read;
    Option.iter toxicity ~f:Pipe.close_read;
    result
;;

module Hyperliquid_live = Session.Make (Hl_mm.Hl_venue.Trading)
module Binance_live = Session.Make (Binance_client.Venue)
module Bybit_live = Session.Make (Bybit_client.Venue)

let parse_address s =
  Or_error.try_with (fun () ->
    match String.chop_prefix s ~prefix:"0x" with
    | Some hex when String.length hex = 40 && String.for_all hex ~f:Char.is_hex_digit ->
      Hl_protocol.Address.of_string s
    | _ -> raise_s [%message "expected 0x followed by 40 hex digits" s])
;;

let private_key_var = "HL_PRIVATE_KEY"

let private_key ~getenv =
  match getenv private_key_var with
  | None | Some "" -> Ok None
  | Some hex ->
    (* As [Hl_client.Signing.Private_key.of_env], but through [getenv]. The error leaves
       out [of_hex]'s, which can quote digits of the key. *)
    (match Hl_client.Signing.Private_key.of_hex (String.strip hex) with
     | Ok key -> Ok (Some key)
     | Error _ ->
       Or_error.error_s
         [%message "not a secp256k1 private key (64 hex digits)" ~var:private_key_var])
;;

let hyperliquid ?base_url ?address ?(allow_mainnet = false) ~getenv ~network () =
  let open Or_error.Let_syntax in
  let%bind key = private_key ~getenv in
  let%bind address =
    match Option.first_some address (getenv "HL_ADDRESS"), key, network with
    | Some address, _, _ -> parse_address address >>| Option.some
    | None, Some _, _ -> return None (* the key's address *)
    | None, None, Network.Local -> parse_address simulator_address >>| Option.some
    | None, None, (Testnet | Mainnet) ->
      Or_error.error_string
        "Hyperliquid needs HL_PRIVATE_KEY (or -address or HL_ADDRESS) off the simulator"
  in
  let config =
    match base_url, (network : Network.t) with
    | Some base_url, _ -> Hl_client.Config.create ?address ~base_url ()
    | None, Local -> Hl_client.Config.local ?address ()
    | None, Testnet -> Hl_client.Config.testnet ?address ()
    | None, Mainnet -> Hl_client.Config.mainnet ?address ()
  in
  let handle = Hl_client.Client.trading ?key config in
  let signed = Option.is_some key in
  let mainnet = Network.equal network Mainnet || Hl_client.Client.is_mainnet handle in
  let%bind () =
    if signed && mainnet && not allow_mainnet
    then
      Or_error.error_s
        [%message
          "refusing to sign orders for Hyperliquid mainnet without -i-understand-mainnet"
            ~base_url:(Uri.to_string config.base_url)]
    else return ()
  in
  let%map account =
    match (Hl_client.Client.config handle).address with
    | Some address -> return address
    | None -> Or_error.error_string "Hyperliquid: no account address"
  in
  (module struct
    let venue = Venue_choice.Hyperliquid

    let endpoint =
      sprintf
        "%s (account %s, %s)"
        (Uri.to_string config.base_url)
        (Hl_protocol.Address.to_string account)
        (if signed
         then
           sprintf
             "signed for %s"
             (if Hl_client.Client.is_mainnet handle then "mainnet" else "testnet")
         else "unsigned")
    ;;

    let min_notional _ = Deferred.Or_error.return (Some hyperliquid_min_notional)

    let[@warning "-unerasable-optional-argument"] connect_and_run
      ?time_source
      ?reload
      ?shadow_params
      ?strategy_log
      ?order_log
      ?cycle_monitor
      ?reference
      ?toxicity
      ~symbol
      ~params
      ~summary_interval
      ~stop
      =
      with_sources
        ~venue
        ~base_url:config.base_url
        ~symbol
        ?reference
        ?toxicity
        (fun ?reference ?toxicity () ->
           Hyperliquid_live.connect_and_run
             ?time_source
             ?reload
             ?shadow_params
             ?strategy_log
             ?order_log:(order_log_spec ~venue order_log)
             ?cycle_monitor
             ?reference
             ?toxicity
             handle
             ~symbol
             ~params
             ~summary_interval
             ~stop)
    ;;
  end : RUNNER)
;;

(* Testnet and mainnet need real credentials; the simulators take any key. *)
let credentials ~getenv ~network ~key_var ~secret_var =
  match getenv key_var, getenv secret_var, (network : Network.t) with
  | Some key, secret, Local -> Ok (key, secret)
  | None, secret, Local -> Ok (local_api_key, secret)
  | Some key, Some secret, (Testnet | Mainnet) -> Ok (key, Some secret)
  | _, _, (Testnet | Mainnet) ->
    Or_error.error_s
      [%message
        "set the API key and secret in the environment"
          (key_var : string)
          (secret_var : string)]
;;

let binance ?base_url ~getenv ~network () =
  let open Or_error.Let_syntax in
  let%map api_key, api_secret =
    credentials
      ~getenv
      ~network
      ~key_var:"BINANCE_API_KEY"
      ~secret_var:"BINANCE_API_SECRET"
  in
  let config =
    match base_url, (network : Network.t), api_secret with
    | Some base_url, _, _ ->
      Binance_client.Config.create ?api_secret ~base_url ~api_key ()
    | None, Local, _ -> Binance_client.Config.local ?api_secret ~api_key ()
    | None, Testnet, Some api_secret ->
      Binance_client.Config.testnet ~api_key ~api_secret ()
    | None, Mainnet, Some api_secret ->
      Binance_client.Config.mainnet ~api_key ~api_secret ()
    | None, (Testnet | Mainnet), None -> assert false (* [credentials] requires it *)
  in
  (module struct
    let venue = Venue_choice.Binance
    let endpoint = Uri.to_string config.base_url

    let min_notional symbol =
      let%map.Deferred.Or_error info = Binance_client.Rest.exchange_info config in
      Binance_protocol.Exchange_info.find_symbol info symbol
      |> Option.bind ~f:Binance_protocol.Exchange_info.Symbol_info.min_notional
    ;;

    let[@warning "-unerasable-optional-argument"] connect_and_run
      ?time_source
      ?reload
      ?shadow_params
      ?strategy_log
      ?order_log
      ?cycle_monitor
      ?reference
      ?toxicity
      ~symbol
      ~params
      ~summary_interval
      ~stop
      =
      with_sources
        ~venue
        ~base_url:config.base_url
        ~symbol
        ?reference
        ?toxicity
        (fun ?reference ?toxicity () ->
           Binance_live.connect_and_run
             ?time_source
             ?reload
             ?shadow_params
             ?strategy_log
             ?order_log:(order_log_spec ~venue order_log)
             ?cycle_monitor
             ?reference
             ?toxicity
             config
             ~symbol
             ~params
             ~summary_interval
             ~stop)
    ;;
  end : RUNNER)
;;

let bybit ?base_url ~getenv ~network () =
  let open Or_error.Let_syntax in
  let%map api_key, api_secret =
    credentials ~getenv ~network ~key_var:"BYBIT_API_KEY" ~secret_var:"BYBIT_API_SECRET"
  in
  let config =
    match base_url, (network : Network.t) with
    | Some base_url, _ -> Bybit_client.Config.create ?api_secret ~api_key ~base_url ()
    | None, Local -> Bybit_client.Config.local ?api_secret ~api_key ()
    | None, Testnet -> Bybit_client.Config.testnet ?api_secret ~api_key ()
    | None, Mainnet -> Bybit_client.Config.mainnet ?api_secret ~api_key ()
  in
  (module struct
    let venue = Venue_choice.Bybit
    let endpoint = Uri.to_string config.base_url

    let min_notional symbol =
      let%map.Deferred.Or_error instruments =
        Bybit_client.Rest.instruments_info ~symbol config
      in
      List.find instruments ~f:(fun (i : Bybit_protocol.Instruments_info.Instrument.t) ->
        Symbol.equal i.symbol symbol)
      |> Option.bind ~f:(fun (i : Bybit_protocol.Instruments_info.Instrument.t) ->
        i.lot_size_filter.min_notional_value)
    ;;

    let[@warning "-unerasable-optional-argument"] connect_and_run
      ?time_source
      ?reload
      ?shadow_params
      ?strategy_log
      ?order_log
      ?cycle_monitor
      ?reference
      ?toxicity
      ~symbol
      ~params
      ~summary_interval
      ~stop
      =
      with_sources
        ~venue
        ~base_url:config.base_url
        ~symbol
        ?reference
        ?toxicity
        (fun ?reference ?toxicity () ->
           Bybit_live.connect_and_run
             ?time_source
             ?reload
             ?shadow_params
             ?strategy_log
             ?order_log:(order_log_spec ~venue order_log)
             ?cycle_monitor
             ?reference
             ?toxicity
             config
             ~symbol
             ~params
             ~summary_interval
             ~stop)
    ;;
  end : RUNNER)
;;

let runner
  ?base_url
  ?address
  ?allow_mainnet
  ?(getenv = Sys.getenv)
  (venue : Venue_choice.t)
  ~network
  =
  match venue with
  | Hyperliquid -> hyperliquid ?base_url ?address ?allow_mainnet ~getenv ~network ()
  | Binance -> binance ?base_url ~getenv ~network ()
  | Bybit -> bybit ?base_url ~getenv ~network ()
;;
