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
