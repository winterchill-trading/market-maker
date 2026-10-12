open! Core
open! Async
open Market_maker

let env bindings name = List.Assoc.find bindings name ~equal:String.equal

let show ?base_url ?address ?(env_bindings = []) venue ~network =
  match
    Venues.runner
      ?base_url:(Option.map base_url ~f:Uri.of_string)
      ?address
      ~getenv:(env env_bindings)
      venue
      ~network
  with
  | Ok (module Runner) ->
    print_s
      [%message
        "" ~venue:(Venues.Venue_choice.to_string Runner.venue) ~endpoint:Runner.endpoint]
  | Error error -> print_s [%sexp (error : Error.t)]
;;

let%expect_test "venue names and default symbols" =
  List.iter [ "hyperliquid"; "HL"; "Binance"; "bybit" ] ~f:(fun s ->
    let venue = Venues.Venue_choice.of_string s in
    print_s
      [%message
        s
          (venue : Venues.Venue_choice.t)
          ~symbol:(Venues.Venue_choice.default_symbol venue : Exchange_core.Symbol.t)
          ~port:(Venues.Venue_choice.default_port venue : int)]);
  [%expect
    {|
    (hyperliquid (venue Hyperliquid) (symbol BTC) (port 3000))
    (HL (venue Hyperliquid) (symbol BTC) (port 3000))
    (Binance (venue Binance) (symbol BTCUSDT) (port 3300))
    (bybit (venue Bybit) (symbol BTCUSDT) (port 3400))
    |}];
  return ()
;;

let%expect_test "local endpoints and base url overrides" =
  show Hyperliquid ~network:Local;
  show Binance ~network:Local;
  show Bybit ~network:Local;
  show Binance ~network:Local ~base_url:"http://127.0.0.1:9999";
  show
    Hyperliquid
    ~network:Local
    ~env_bindings:[ "HL_ADDRESS", "0x00000000000000000000000000000000000000aa" ];
  [%expect
    {|
    ((venue hyperliquid)
     (endpoint
      "http://localhost:3000 (account 0x0000000000000000000000000000000000006d6d)"))
    ((venue binance) (endpoint http://localhost:3300))
    ((venue bybit) (endpoint http://localhost:3400))
    ((venue binance) (endpoint http://127.0.0.1:9999))
    ((venue hyperliquid)
     (endpoint
      "http://localhost:3000 (account 0x00000000000000000000000000000000000000aa)"))
    |}];
  return ()
;;

let%expect_test "real networks need credentials" =
  show Hyperliquid ~network:Mainnet;
  show Binance ~network:Testnet ~env_bindings:[ "BINANCE_API_KEY", "k" ];
  show Bybit ~network:Mainnet;
  show Hyperliquid ~network:Local ~address:"0x12";
  show
    Bybit
    ~network:Testnet
    ~env_bindings:[ "BYBIT_API_KEY", "k"; "BYBIT_API_SECRET", "s" ];
  [%expect
    {|
    "Hyperliquid needs -address or HL_ADDRESS off the simulator"
    ("set the API key and secret in the environment" (key_var BINANCE_API_KEY)
     (secret_var BINANCE_API_SECRET))
    ("set the API key and secret in the environment" (key_var BYBIT_API_KEY)
     (secret_var BYBIT_API_SECRET))
    ("expected 0x followed by 40 hex digits" 0x12)
    ((venue bybit) (endpoint https://api-testnet.bybit.com))
    |}];
  return ()
;;
