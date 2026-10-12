open! Core
open Exchange_core
open Market_maker

let btc = Symbol.of_string "BTC"
let ms n = 1_800_000_000_000_000_000 + (n * 1_000_000)

let request side px cloid =
  Order_request.limit
    ~tif:Alo
    ~client_order_id:(Client_order_id.of_string cloid)
    btc
    side
    ~px:(Price.of_string px)
    ~size:(Size.of_string "0.002")
;;

let fill ~order_id side px size : Order_event.t =
  Fill
    { trade_id = Trade_id.of_int order_id
    ; order_id = Order_id.of_int order_id
    ; client_order_id = None
    ; symbol = btc
    ; side
    ; px = Price.of_string px
    ; size = Size.of_string size
    ; fee = Usd.of_string "0.01"
    ; is_maker = true
    ; time = 0
    ; closed_pnl = None
    }
;;

let%expect_test "resting orders, position and ack latency from the rows" =
  let bid = request Buy "99990" "b1" in
  let ask = request Sell "100010" "a1" in
  let events : (int * Order_event.t) list =
    [ 0, Place [ bid; ask ]
    ; ( 3
      , Placed
          { requests = [ bid; ask ]
          ; result =
              Ok
                [ Resting { order_id = Order_id.of_int 1; client_order_id = None }
                ; Resting { order_id = Order_id.of_int 2; client_order_id = None }
                ]
          } )
    ; 500, fill ~order_id:1 Buy "99990" "0.0005"
    ; 900, fill ~order_id:2 Sell "100010" "0.002"
    ; 1000, Cancel { symbol = btc; order_ids = [ Order_id.of_int 1 ] }
    ]
  in
  let status =
    List.fold
      events
      ~init:
        (Order_log_status.add_row
           Order_log_status.empty
           (Order_log.parse_line Order_log.header))
      ~f:(fun status (at, event) ->
        List.fold
          (Order_log.rows ~venue:"hyperliquid" ~local_ts:(ms at) event)
          ~init:status
          ~f:(fun status row ->
            Order_log_status.add_row status (Order_log.parse_line row)))
  in
  List.iter (Order_log_status.to_lines status ~now_ns:(ms 2000)) ~f:print_endline;
  [%expect
    {|
    hyperliquid BTC  last row 1.0s ago
    position -0.0015  volume 250.015 USD  fees 0.02 USD
    place 2  ack 2  cancel 1  fill 2  update 0
    ack latency median 3.00ms max 3.00ms (last 2)
    resting orders (1)
      buy  0.0015 @ 99990
    recent fills
      1.1s ago  sell 0.002 @ 100010
      1.5s ago  buy  0.0005 @ 99990
    |}];
  (* The cancel's answer removes the bid. *)
  let status =
    List.fold
      (Order_log.rows
         ~venue:"hyperliquid"
         ~local_ts:(ms 1004)
         (Cancelled { symbol = btc; order_ids = [ Order_id.of_int 1 ]; result = Ok () }))
      ~init:status
      ~f:(fun status row -> Order_log_status.add_row status (Order_log.parse_line row))
  in
  print_s [%sexp (Map.keys (Order_log_status.resting status) : string list)];
  [%expect {| () |}]
;;
