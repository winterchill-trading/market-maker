open! Core
open! Async
open Market_maker

let%expect_test "complete lines only, then a restart after truncation" =
  let path = Filename_unix.temp_file "order_log_tail" ".csv" in
  let tail = Order_log_tail.create path in
  let read () =
    let%map result = Order_log_tail.read_new tail in
    print_s [%sexp (result : [ `Lines of string list | `Restart ])]
  in
  let%bind () = Writer.save path ~contents:"a,1\nb,2\nc," in
  let%bind () = read () in
  let%bind () =
    Writer.with_file ~append:true path ~f:(fun w ->
      Writer.write w "3\nd,4\n";
      return ())
  in
  let%bind () = read () in
  let%bind () = read () in
  let%bind () = Writer.save path ~contents:"e\n" in
  let%bind () = read () in
  let%bind () = read () in
  [%expect {|
    (Lines (a,1 b,2))
    (Lines (c,3 d,4))
    (Lines ())
    Restart
    (Lines (e))
    |}];
  return ()
;;
