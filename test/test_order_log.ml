open! Core
open! Async
open Exchange_core
open Market_maker

let print event =
  List.iter (Order_log.rows ~venue:"binance" ~local_ts:1_000 event) ~f:print_endline
;;

let request side px =
  Order_request.limit
    ~tif:Alo
    ~client_order_id:(Client_order_id.of_string "c1")
    (Symbol.of_string "BTCUSDT")
    side
    ~px:(Price.of_string px)
    ~size:(Size.of_string "0.002")
;;

let%expect_test "one row per order, quoted where needed" =
  print_endline Order_log.header;
  let requests = [ request Buy "99990"; request Sell "100010" ] in
  print (Place requests);
  print
    (Placed
       { requests
       ; result =
           Ok
             [ Resting
                 { order_id = Order_id.of_int 11
                 ; client_order_id = Some (Client_order_id.of_string "c1")
                 }
             ; Rejected (Post_only_would_cross { best_bid = None; best_ask = None })
             ]
       });
  print (Placed { requests; result = Error (Error.of_string "timeout, \"retry\"") });
  print
    (Cancelled
       { symbol = Symbol.of_string "BTCUSDT"
       ; order_ids = [ Order_id.of_int 11 ]
       ; result = Ok ()
       });
  print
    (Update
       { order_id = Order_id.of_int 11
       ; client_order_id = None
       ; symbol = Symbol.of_string "BTCUSDT"
       ; side = Buy
       ; px = Price.of_string "99990"
       ; status = Partially_filled
       ; filled = Size.of_string "0.001"
       ; remaining = Size.of_string "0.001"
       ; time = 900
       });
  print
    (Fill
       { trade_id = Trade_id.of_int 5
       ; order_id = Order_id.of_int 11
       ; client_order_id = None
       ; symbol = Symbol.of_string "BTCUSDT"
       ; side = Buy
       ; px = Price.of_string "99990"
       ; size = Size.of_string "0.001"
       ; fee = Usd.of_string "0.02"
       ; is_maker = true
       ; time = 900
       ; closed_pnl = None
       });
  [%expect
    {|
    local_ts,venue_ts,venue,symbol,event,side,price,size,order_id,client_order_id,status,trade_id,fee,detail
    1000,,binance,BTCUSDT,place,buy,99990,0.002,,c1,,,,
    1000,,binance,BTCUSDT,place,sell,100010,0.002,,c1,,,,
    1000,,binance,BTCUSDT,ack,buy,99990,0.002,11,c1,resting,,,
    1000,,binance,BTCUSDT,ack,sell,100010,0.002,,c1,rejected,,,(Post_only_would_cross(best_bid())(best_ask()))
    1000,,binance,BTCUSDT,ack,buy,99990,0.002,,c1,error,,,"timeout, ""retry"""
    1000,,binance,BTCUSDT,ack,sell,100010,0.002,,c1,error,,,"timeout, ""retry"""
    1000,,binance,BTCUSDT,cancel_ack,,,,11,,ok,,,
    1000,900,binance,BTCUSDT,update,buy,99990,0.001,11,,partially_filled,,,filled 0.001
    1000,900,binance,BTCUSDT,fill,buy,99990,0.001,11,,maker,5,0.02,
    |}];
  return ()
;;

let%expect_test "parse_line reads back what rows writes" =
  let rows =
    Order_log.rows
      ~venue:"binance"
      ~local_ts:1_000
      (Placed
         { requests = [ request Buy "99990" ]
         ; result = Error (Error.of_string "timeout, \"retry\"")
         })
  in
  List.iter rows ~f:(fun row -> print_s [%sexp (Order_log.parse_line row : string list)]);
  print_s [%sexp (Order_log.parse_line Order_log.header |> List.length : int)];
  print_s [%sexp (Order_log.parse_line ",," : string list)];
  [%expect
    {|
    (1000 "" binance BTCUSDT ack buy 99990 0.002 "" c1 error "" ""
     "timeout, \"retry\"")
    14
    ("" "" "")
    |}];
  return ()
;;

let%expect_test "plausibility rows" =
  let symbol = Symbol.of_string "BTCUSDT" in
  let guard e = print (Plausibility { symbol; event = Reference e }) in
  let gate e = print (Plausibility { symbol; event = Toxicity e }) in
  guard
    (Diverged
       { divergence_bps = 61.234
       ; held_ms = 2_000
       ; venue_mid = Price.of_string "100612"
       ; reference_mid = Price.of_string "100000"
       });
  guard
    (Reference_jumped
       { from_ = Price.of_string "100000"
       ; to_ = Price.of_string "101000"
       ; jump_bps = 100.
       });
  guard (Reference_missing { age_ms = None });
  guard (Reference_missing { age_ms = Some 31_000 });
  guard Resumed;
  gate (Widening { signal = 0.83 });
  gate (Pulled { signal = 0.97 });
  gate Cleared;
  print (Toxicity { symbol; signal = 0.5; imbalance = -0.25; decision = Normal });
  print
    (Toxicity
       { symbol
       ; signal = 0.875
       ; imbalance = 0.6
       ; decision =
           Widen
             { intensity = 0.5
             ; extra_half_spread_bps = 2.5
             ; reservation_shift_bps = 0.6
             ; size_factor = 0.75
             }
       });
  print
    (Toxicity { symbol; signal = 0.99; imbalance = 1.; decision = Pull { signal = 0.99 } });
  [%expect {| |}];
  return ()
;;
