open! Core
open! Async
open Market_maker

let instrument = Market_data.Instrument.of_string "hyperliquid:BTC"

(* [n] trades of 0.01 on [side], one a second from [from]. *)
let trades ~from ~n side =
  List.init n ~f:(fun i ->
    let ts =
      Time_ns.add Session_helpers.start_time (Time_ns.Span.of_int_sec (from + i))
    in
    { Market_data.Trade.instrument
    ; exch_ts = ts
    ; recv_ts = ts
    ; price = Market_data.Price.of_string "100000"
    ; size = Market_data.Size.of_string "0.01"
    ; side
    ; trade_id = Int.to_string (from + i)
    })
;;

(* Balanced flow (buckets of 0.04: two buys and two sells), then one-sided buying. *)
let tape =
  List.concat_map (List.range 0 6) ~f:(fun k ->
    trades ~from:(4 * k) ~n:2 Buy @ trades ~from:((4 * k) + 2) ~n:2 Sell)
  @ trades ~from:24 ~n:16 Buy
;;

let show kind =
  let config =
    ok_exn
      (Toxicity_source.Config.create
         ~window:3
         ~kind
         ~bucket_volume:(Market_data.Size.of_string "0.04")
         ())
  in
  let%map signals =
    Toxicity_source.of_trades config (Pipe.of_list tape) |> Pipe.to_list
  in
  List.iter signals ~f:(fun { Toxicity_source.Signal.signal; imbalance } ->
    printf
      "%s signal %.3f imbalance %+.2f\n"
      (Toxicity_source.Kind.to_string kind)
      signal
      imbalance)
;;

let%expect_test "VPIN rises bucket by bucket under one-sided flow; its percentile jumps \
                 to 1"
  =
  let%bind () = show Vpin in
  [%expect
    {|
    vpin signal 0.000 imbalance +0.00
    vpin signal 0.000 imbalance +0.00
    vpin signal 0.000 imbalance +0.00
    vpin signal 0.000 imbalance +0.00
    vpin signal 0.333 imbalance +1.00
    vpin signal 0.667 imbalance +1.00
    vpin signal 1.000 imbalance +1.00
    |}];
  let%bind () = show Percentile in
  [%expect
    {|
    percentile signal 0.500 imbalance +0.00
    percentile signal 0.500 imbalance +0.00
    percentile signal 0.500 imbalance +0.00
    percentile signal 0.500 imbalance +0.00
    percentile signal 0.500 imbalance +0.00
    percentile signal 1.000 imbalance +1.00
    percentile signal 1.000 imbalance +1.00
    percentile signal 1.000 imbalance +1.00
    |}];
  return ()
;;
