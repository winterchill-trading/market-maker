open! Core
open! Async
open Market_maker

let%expect_test "reference specs" =
  List.iter
    [ "anchor"
    ; "binance:BTCUSDT"
    ; "hl:BTC@http://127.0.0.1:3000"
    ; "Bybit:BTCUSDT"
    ; "okx:BTC-USDT"
    ; "binance:"
    ; "mid"
    ]
    ~f:(fun s ->
      match Reference_source.Spec.of_string s with
      | Ok spec ->
        print_s
          [%message
            s
              ~_:(spec : Reference_source.Spec.t)
              ~to_string:(Reference_source.Spec.to_string spec)]
      | Error error -> print_s [%message s ~_:(error : Error.t)]);
  [%expect
    {|
    (anchor Anchor (to_string anchor))
    (binance:BTCUSDT (Feed (venue binance) (symbol BTCUSDT) (base_url ()))
     (to_string binance:BTCUSDT))
    (hl:BTC@http://127.0.0.1:3000
     (Feed (venue hyperliquid) (symbol BTC) (base_url (http://127.0.0.1:3000)))
     (to_string hyperliquid:BTC@http://127.0.0.1:3000))
    (Bybit:BTCUSDT (Feed (venue bybit) (symbol BTCUSDT) (base_url ()))
     (to_string bybit:BTCUSDT))
    (okx:BTC-USDT
     ("unknown reference venue" okx (expected (hyperliquid binance bybit))))
    (binance: ("missing reference symbol" (reference binance:)))
    (mid ("expected anchor or <venue>:<symbol>[@<base url>]" (reference mid)))
    |}];
  return ()
;;

let%expect_test "anchor status of each simulator" =
  let show json =
    let anchors = Reference_source.Anchor_status.of_json (Yojson.Safe.from_string json) in
    print_s
      [%message
        ""
          (anchors : Reference_source.Anchor_status.t list)
          ~btc:
            (Reference_source.Anchor_status.reference anchors ~symbol:"BTC"
             : Exchange_core.Price.t option)
          ~btcusdt:
            (Reference_source.Anchor_status.reference anchors ~symbol:"BTCUSDT"
             : Exchange_core.Price.t option)]
  in
  (* hl-sim: [GET /status], anchors named by their spec. *)
  show
    {|{"ws_connections": 1, "anchors": [
        {"anchor": "hyperliquid:BTC", "fresh": true, "reference_price": "100012"},
        {"anchor": "binance:ETHUSDT=ETH", "fresh": false, "reference_price": "3500.5"}]}|};
  (* binance-sim: [GET /sim/anchor], [state] fresh or stale. *)
  show
    {|[{"reference": "bybit:BTCUSDT", "sim_symbol": "BTCUSDT", "state": "stale",
        "reference_price": "99990.1"}]|};
  (* bybit-sim: [GET /sim/anchor], [symbol] and [fresh]; no price yet. *)
  show {|[{"symbol": "BTCUSDT", "fresh": true, "reference_price": null}]|};
  show {|{"ws_connections": 0}|};
  [%expect
    {|
    ((anchors
      (((symbol BTC) (fresh true) (reference_price (100012)))
       ((symbol ETH) (fresh false) (reference_price (3500.5)))))
     (btc (100012)) (btcusdt ()))
    ((anchors (((symbol BTCUSDT) (fresh false) (reference_price (99990.1)))))
     (btc ()) (btcusdt ()))
    ((anchors (((symbol BTCUSDT) (fresh true) (reference_price ())))) (btc ())
     (btcusdt ()))
    ((anchors ()) (btc ()) (btcusdt ()))
    |}];
  return ()
;;
