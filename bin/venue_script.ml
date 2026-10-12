(* One order sequence, the same on every venue, between two accounts (a maker and a taker)
   on a simulator without noise traders, printed in a venue-neutral form so that
   scripts/compare-venues.sh can diff two venues line by line. *)

open! Core
open! Async
open Exchange_core

let px = Price.of_string
let sz = Size.of_string

module Run (V : Mm_core.Venue.S) = struct
  let show_status : Order_status.t -> string = function
    | Resting _ -> "resting"
    | Filled { total; avg_px; _ } ->
      sprintf "filled %s @ %s" (Size.to_string total) (Price.to_string avg_px)
    | Rejected reason -> "rejected: " ^ Mm_core.Live.describe_reject reason
  ;;

  let place venue label request =
    match%map V.place venue [ request ] with
    | Ok [ status ] ->
      printf "%-34s %s\n" label (show_status status);
      (match status with
       | Resting { order_id; _ } | Filled { order_id; _ } -> Some order_id
       | Rejected _ -> None)
    | Ok statuses ->
      printf "%-34s %d statuses\n" label (List.length statuses);
      None
    | Error error ->
      printf "%-34s error %s\n" label (Error.to_string_hum error);
      None
  ;;

  let cancel venue symbol label oids =
    let%map result = V.cancel venue symbol oids in
    printf
      "%-34s %s\n"
      label
      (match result with
       | Ok () -> "ok"
       | Error error -> "error " ^ Error.to_string_hum error)
  ;;

  let show_fill name (f : Mm_core.Fill.t) =
    let notional = Price.to_float f.px *. Size.to_float f.size in
    printf
      "fill %-6s %-4s %s @ %s %s fee %.2fbps\n"
      name
      (match f.side with
       | Buy -> "buy"
       | Sell -> "sell")
      (Size.to_string f.size)
      (Price.to_string f.px)
      (if f.is_maker then "maker" else "taker")
      (if Float.(notional > 0.) then Usd.to_float f.fee /. notional *. 10_000. else 0.)
  ;;

  let show_account name venue symbol =
    let%bind account = V.account venue in
    let%map orders = V.open_orders venue symbol in
    let position =
      match account with
      | Error error -> "error " ^ Error.to_string_hum error
      | Ok (a : Account_view.t) ->
        List.find a.positions ~f:(fun (p : Position_view.t) ->
          Symbol.equal p.symbol symbol)
        |> Option.value_map ~default:"0" ~f:(fun (p : Position_view.t) ->
          Size.to_string p.size)
    in
    printf
      "%-6s position %s, %s\n"
      name
      position
      (match orders with
       | Error error -> "open orders error " ^ Error.to_string_hum error
       | Ok orders ->
         sprintf
           "open orders [%s]"
           (List.map orders ~f:(fun (o : Open_order.t) ->
              sprintf
                "%s %s@%s"
                (match o.side with
                 | Buy -> "buy"
                 | Sell -> "sell")
                (Size.to_string o.size)
                (Price.to_string o.px))
            |> String.concat ~sep:" "))
  ;;

  let run ~maker ~taker ~symbol =
    let%bind.Deferred.Or_error m = V.connect maker in
    let%bind.Deferred.Or_error t = V.connect taker in
    let fills = Queue.create () in
    let collect name venue =
      don't_wait_for
        (Pipe.iter_without_pushback (V.fills venue) ~f:(fun f ->
           Queue.enqueue fills (name, f)))
    in
    collect "maker" m;
    collect "taker" t;
    let limit ?tif ?reduce_only side p s =
      Order_request.limit ?tif ?reduce_only symbol side ~px:(px p) ~size:(sz s)
    in
    let%bind bid =
      place m "maker alo buy 0.01@99000" (limit ~tif:Alo Buy "99000" "0.01")
    in
    let%bind ask =
      place m "maker alo sell 0.01@101000" (limit ~tif:Alo Sell "101000" "0.01")
    in
    let%bind _ =
      place t "taker alo buy 0.01@101000 (crosses)" (limit ~tif:Alo Buy "101000" "0.01")
    in
    let%bind _ = place t "taker gtc buy 0.004@101000" (limit Buy "101000" "0.004") in
    let%bind _ =
      place t "taker ioc sell 0.02@98000" (limit ~tif:Ioc Sell "98000" "0.02")
    in
    let%bind _ =
      place
        t
        "taker market buy 0.003"
        (Order_request.market symbol Buy ~size:(sz "0.003"))
    in
    let%bind _ =
      place m "maker gtc buy 0.001@101000 (self)" (limit Buy "101000" "0.001")
    in
    let%bind _ =
      place t "taker ioc buy 0.001@100000 (empty)" (limit ~tif:Ioc Buy "100000" "0.001")
    in
    let%bind _ =
      place
        t
        "taker reduce-only sell 0.001@98000"
        (limit ~reduce_only:true Sell "98000" "0.001")
    in
    let%bind _ =
      place
        t
        "taker reduce-only buy 0.01@101000"
        (limit ~reduce_only:true Buy "101000" "0.01")
    in
    let%bind _ =
      place t "taker gtc buy 0.001@99000.5 (tick)" (limit Buy "99000.5" "0.001")
    in
    let%bind _ =
      place t "taker gtc buy 0.0005@90000 (lot)" (limit Buy "90000" "0.0005")
    in
    let%bind _ = place t "taker gtc buy 0.001@90000 ($90)" (limit Buy "90000" "0.001") in
    let%bind () =
      cancel m symbol "maker cancel the rest" (List.filter_opt [ bid; ask ])
    in
    let%bind () = cancel m symbol "maker cancel again" (List.filter_opt [ bid; ask ]) in
    let%bind () = V.cancel_all t symbol >>| ignore in
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1500) in
    Queue.iter fills ~f:(fun (name, f) -> show_fill name f);
    let%bind () = show_account "maker" m symbol in
    let%bind () = show_account "taker" t symbol in
    let%bind () = V.close m in
    let%map () = V.close t in
    Ok ()
  ;;
end

module Hyperliquid = Run (Hl_mm.Hl_venue)
module Binance = Run (Binance_client.Venue)

let command =
  Command.async_or_error
    ~summary:"Run the venue comparison order sequence against a simulator"
    (let%map_open.Command venue =
       flag
         "-venue"
         (required Market_maker.Venues.Venue_choice.arg_type)
         ~doc:"VENUE hyperliquid or binance"
     and base_url = flag "-base-url" (required string) ~doc:"URL the simulator" in
     fun () ->
       Log.Global.set_level `Error;
       let base_url = Uri.of_string base_url in
       match venue with
       | Hyperliquid ->
         let config address =
           Hl_client.Config.create
             ~address:(Hl_protocol.Address.of_string address)
             ~base_url
             ()
         in
         Hyperliquid.run
           ~maker:(config "0x00000000000000000000000000000000000000aa")
           ~taker:(config "0x00000000000000000000000000000000000000bb")
           ~symbol:(Symbol.of_string "BTC")
       | Binance ->
         let config api_key = Binance_client.Config.create ~base_url ~api_key () in
         Binance.run
           ~maker:(config "maker")
           ~taker:(config "taker")
           ~symbol:(Symbol.of_string "BTCUSDT")
       | Bybit -> Deferred.Or_error.error_string "only hyperliquid and binance")
;;

let () = Command_unix.run command
