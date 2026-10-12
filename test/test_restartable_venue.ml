open! Core
open! Async
open Market_maker
module V = Restartable_venue.Make (Fake_venue)

let%expect_test "a second loop gets the feeds, close waits for shutdown" =
  let fake = Fake_venue.create () in
  let%bind t = V.connect fake >>| ok_exn in
  let%bind _ =
    V.place
      t
      [ Exchange_core.Order_request.limit
          Fake_venue.btc
          Buy
          ~px:(Exchange_core.Price.of_string "100")
          ~size:(Exchange_core.Size.of_string "1")
      ]
  in
  let first_fills = V.fills t in
  let%bind first_books = V.books t Fake_venue.btc in
  let hooks = ref [] in
  V.on_reconnect t ~f:(fun () -> hooks := "first" :: !hooks);
  V.next_loop t;
  V.on_reconnect t ~f:(fun () -> hooks := "second" :: !hooks);
  let second_fills = V.fills t in
  Fake_venue.fill_best fake Buy;
  Fake_venue.reconnect fake;
  let%bind () = V.close t in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  print_s
    [%message
      ""
        ~first_fills_closed:(Pipe.is_closed first_fills : bool)
        ~first_books_closed:(Pipe.is_closed first_books : bool)
        ~second_fills:(Pipe.length second_fills : int)
        ~hooks:(!hooks : string list)
        ~fake_closed:(Fake_venue.closed fake : bool)];
  let%bind () = V.shutdown t in
  print_s [%message "" ~fake_closed:(Fake_venue.closed fake : bool)];
  [%expect
    {|
    ((first_fills_closed true) (first_books_closed true) (second_fills 1)
     (hooks (second)) (fake_closed false))
    (fake_closed true)
    |}];
  return ()
;;

let%expect_test "observers see what the strategy is fed" =
  let fake = Fake_venue.create () in
  let%bind t = V.connect fake >>| ok_exn in
  V.add_observer t (fun input ->
    print_endline
      (match input with
       | Book book -> sprintf "book, %d bids" (List.length book.bids)
       | Fill fill -> sprintf "fill %s" (Exchange_core.Trade_id.to_string fill.trade_id)
       | Open_orders orders -> sprintf "open orders, %d" (List.length orders)
       | Account account ->
         sprintf "account, equity %s" (Exchange_core.Usd.to_string account.equity)));
  Fake_venue.push_book fake ~bid:"99" ~ask:"101";
  let%bind books = V.books t Fake_venue.btc in
  let%bind _ = Pipe.read books in
  let%bind _ =
    V.place
      t
      [ Exchange_core.Order_request.limit
          Fake_venue.btc
          Sell
          ~px:(Exchange_core.Price.of_string "101")
          ~size:(Exchange_core.Size.of_string "1")
      ]
  in
  let%bind _ = V.open_orders t Fake_venue.btc in
  let%bind _ = V.account t in
  Fake_venue.fill_best fake Sell;
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  [%expect
    {|
    book, 1 bids
    open orders, 1
    account, equity 1000
    fill 1
    |}];
  V.shutdown t
;;
