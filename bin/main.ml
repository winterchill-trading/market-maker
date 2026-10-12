open! Core
open! Async
open Exchange_core
open Market_maker
open Mm_core

(* Per-instrument defaults ([Params.for_instrument]): about $100 per order, raised to 1.2x
   the venue's minimum order value, and 10 orders of position room. *)
let params_for
  instrument
  ~mid
  ~min_notional
  ~levels
  ~size
  ~half_spread_bps
  ~skew_bps
  ~max_position
  ~requote_ms
  =
  Or_error.try_with_join (fun () ->
    let base =
      Params.for_instrument
        instrument
        ~mid
        ?min_notional
        ?order_size:(Option.map size ~f:Size.of_string)
        ?max_position:(Option.map max_position ~f:Size.of_string)
    in
    Params.validate
      { base with
        levels = Option.value levels ~default:base.levels
      ; base_half_spread_bps =
          Option.value half_spread_bps ~default:base.base_half_spread_bps
      ; skew_bps = Option.value skew_bps ~default:base.skew_bps
      ; requote_interval_ms = Option.value requote_ms ~default:base.requote_interval_ms
      })
;;

let command =
  Command.async_or_error
    ~summary:"Market maker for Hyperliquid, Binance and Bybit (and their simulators)"
    ~readme:(fun () ->
      "Quotes a post-only ladder around the microprice of one instrument, skewed by \
       inventory, and requotes as the book moves (the mm-core strategy). -network local \
       targets the simulators: hl-sim on :3000, binance-sim on :3300, bybit-sim on \
       :3400. Credentials come from the environment: HL_ADDRESS, BINANCE_API_KEY and \
       BINANCE_API_SECRET, BYBIT_API_KEY and BYBIT_API_SECRET. On SIGINT/SIGTERM, or \
       after -run-for seconds, it cancels every resting order and prints a report (a \
       second SIGINT exits at once).")
    (let%map_open.Command venue =
       flag
         "-venue"
         (required Venues.Venue_choice.arg_type)
         ~doc:"VENUE hyperliquid, binance or bybit"
     and network =
       flag
         "-network"
         (optional_with_default Venues.Network.Local Venues.Network.arg_type)
         ~doc:"NETWORK local (the simulator), testnet or mainnet (default local)"
     and base_url =
       flag
         "-base-url"
         (optional string)
         ~doc:"URL REST root, overriding the network's (websockets derived from it)"
     and address =
       flag
         "-address"
         (optional string)
         ~doc:"ADDRESS Hyperliquid account (default HL_ADDRESS, or a simulator account)"
     and symbol =
       flag
         "-symbol"
         (optional string)
         ~doc:"SYMBOL instrument to quote (default BTC on Hyperliquid, BTCUSDT elsewhere)"
     and levels = flag "-levels" (optional int) ~doc:"N quote levels per side (default 3)"
     and size =
       flag
         "-size"
         (optional string)
         ~doc:
           "SIZE order size per level (default: about 100 USD, above the venue minimum)"
     and half_spread_bps =
       flag
         "-half-spread-bps"
         (optional float)
         ~doc:"BPS distance of the first level from the reservation price (default 3)"
     and skew_bps =
       flag
         "-skew-bps"
         (optional float)
         ~doc:"BPS reservation price shift at full inventory (default 4)"
     and max_position =
       flag
         "-max-position"
         (optional string)
         ~doc:"SIZE absolute position limit (default 10 x size)"
     and requote_ms =
       flag
         "-requote-ms"
         (optional int)
         ~doc:"MS requote and open-orders poll interval (default 1000)"
     and run_for =
       flag
         "-run-for"
         (optional float)
         ~doc:"SECONDS stop after this long, cancel all and print a report"
     and summary_secs =
       flag
         "-summary-secs"
         (optional_with_default 10. float)
         ~doc:"SECONDS interval of the position and quotes summary log (default 10)"
     and log_level =
       flag
         "-log-level"
         (optional_with_default `Info Log.Level.arg)
         ~doc:"LEVEL debug, info, warn or error (default info)"
     in
     fun () ->
       let open Deferred.Or_error.Let_syntax in
       Log.Global.set_output [ Log.Output.stderr () ];
       Log.Global.set_level log_level;
       let symbol =
         match symbol with
         | Some symbol -> Symbol.of_string symbol
         | None -> Venues.Venue_choice.default_symbol venue
       in
       let%bind (module Runner) =
         Venues.runner
           ?base_url:(Option.map base_url ~f:Uri.of_string)
           ?address
           venue
           ~network
         |> Deferred.return
       in
       Log.Global.info_s
         [%message
           "connecting"
             ~venue:(Venues.Venue_choice.to_string venue)
             ~network:(Venues.Network.to_string network)
             ~endpoint:Runner.endpoint
             (symbol : Symbol.t)];
       let%bind min_notional = Runner.min_notional symbol in
       Log.Global.info_s [%message "venue minimum" (min_notional : Usd.t option)];
       let stop =
         Mm_core.Live.stop_signal ?run_for:(Option.map run_for ~f:Time_ns.Span.of_sec) ()
       in
       let%map report =
         Runner.connect_and_run
           ~symbol
           ~params:
             (params_for
                ~min_notional
                ~levels
                ~size
                ~half_spread_bps
                ~skew_bps
                ~max_position
                ~requote_ms)
           ~summary_interval:(Time_ns.Span.of_sec summary_secs)
           ~stop
       in
       printf "--- market-maker report (%s) ---\n" (Venues.Venue_choice.to_string venue);
       print_endline (Mm_core.Live.Report.to_string_hum report))
;;

let () = Command_unix.run command
