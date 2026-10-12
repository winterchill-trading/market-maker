open! Core
open! Async
open Exchange_core
open Market_maker

(* Runs queries/fills_vs_trades.sql with the duckdb CLI (on PATH, or Homebrew's) over an
   order log written by [Order_log] and a trades table shaped like market-data's. *)

let duckdb =
  if Sys_unix.file_exists_exn "/opt/homebrew/bin/duckdb"
  then "/opt/homebrew/bin/duckdb"
  else "duckdb"
;;

let run_sql ~dir sql =
  Process.run_exn ~working_dir:dir ~prog:duckdb ~args:[ "-csv" ] ~stdin:sql ()
;;

let fill ~local_ms ~venue_ms ~trade_id side px size : string list =
  Order_log.rows
    ~venue:"binance"
    ~local_ts:(1_800_000_000_000_000_000 + (local_ms * 1_000_000))
    (Fill
       { trade_id = Trade_id.of_int trade_id
       ; order_id = Order_id.of_int trade_id
       ; client_order_id = None
       ; symbol = Symbol.of_string "BTCUSDT"
       ; side
       ; px = Price.of_string px
       ; size = Size.of_string size
       ; fee = Usd.of_string "0.02"
       ; is_maker = true
       ; time = 1_800_000_000_000_000_000 + (venue_ms * 1_000_000)
       ; closed_pnl = None
       })
;;

let%expect_test "fills matched by trade id, by price and time, and unmatched" =
  let dir = Filename_unix.temp_dir "fills_vs_trades" "" in
  let order_log =
    (Order_log.header
     :: fill ~local_ms:1000 ~venue_ms:990 ~trade_id:500 Buy "99990" "0.002")
    @ fill ~local_ms:2000 ~venue_ms:1995 ~trade_id:9001 Sell "100010" "0.001"
    @ fill ~local_ms:3000 ~venue_ms:2995 ~trade_id:9002 Sell "100020" "0.001"
  in
  let%bind () = Writer.save_lines (dir ^/ "orders.csv") order_log in
  (* Public trade 500 is the first fill; 777 and 778 trade at the second fill's price, and
     only 777 has a buyer as taker against the maker's sell. *)
  let%bind (_ : string) =
    run_sql
      ~dir
      {|
COPY (
  SELECT venue, symbol, make_timestamp_ns(exch) AS exch_ts, make_timestamp_ns(recv) AS recv_ts,
         price::DECIMAL(18, 8) AS price, size::DECIMAL(18, 8) AS size, side, trade_id
  FROM (VALUES
    ('binance', 'BTCUSDT', 1800000000990000000, 1800000001003000000, '99990', '0.002', 'sell', '500'),
    ('binance', 'BTCUSDT', 1800000001995000000, 1800000001998000000, '100010', '0.003', 'buy', '777'),
    ('binance', 'BTCUSDT', 1800000001995000000, 1800000001998000000, '100010', '0.003', 'sell', '778'))
    t(venue, symbol, exch, recv, price, size, side, trade_id)
) TO 'trades.parquet' (FORMAT parquet);
|}
  in
  let query = In_channel.read_all "../queries/fills_vs_trades.sql" in
  let%bind output =
    run_sql
      ~dir
      ("SET VARIABLE order_log = 'orders.csv';\nSET VARIABLE trades = 'trades.parquet';\n"
       ^ query)
  in
  print_string output;
  [%expect
    {|
    venue,symbol,local_ts,venue_ts,side,price,size,is_maker,trade_id,public_trade_id,match,taker_side,exch_lag_ms,public_ms
    binance,BTCUSDT,2027-01-15 08:00:01,2027-01-15 08:00:00.99,buy,99990.00000000,0.00200000,true,500,500,id,sell,0.0,3.0
    binance,BTCUSDT,2027-01-15 08:00:02,2027-01-15 08:00:01.995,sell,100010.00000000,0.00100000,true,9001,777,nearest,buy,0.0,-2.0
    binance,BTCUSDT,2027-01-15 08:00:03,2027-01-15 08:00:02.995,sell,100020.00000000,0.00100000,true,9002,NULL,NULL,NULL,NULL,NULL
    venue,symbol,fills,matched,by_id,median_public_ms,max_exch_lag_ms
    binance,BTCUSDT,3,2,1,0.5,0.0
    |}];
  return ()
;;
