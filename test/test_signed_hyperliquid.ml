open! Core
open! Async
open Hl_protocol
open Market_maker
module Signing = Hl_client.Signing

(* A throwaway key (the secp256k1 secret 1), never funded anywhere. *)
let key_hex = String.make 63 '0' ^ "1"
let maker = Address.of_string "0x00000000000000000000000000000000000000b0"

let order ~is_buy ~px =
  { Order_request.asset = Asset.of_int 0
  ; is_buy
  ; limit_px = Price.of_string px
  ; sz = Size.of_string "0.01"
  ; reduce_only = false
  ; order_type = Limit { tif = Gtc }
  ; cloid = None
  }
;;

(* Who signed a journalled request, recovered from its signature with the testnet domain. *)
let signer (entry : Hl_sim.Journal.Entry.t) =
  match entry.request.signature with
  | None -> "unsigned"
  | Some json ->
    let signature = Signing.Signature.t_of_yojson json in
    let connection_id =
      Signing.action_hash
        ~vault_address:entry.request.vault_address
        ~nonce:entry.request.nonce
        (Exchange_action.yojson_of_t entry.request.action)
    in
    let digest = Signing.l1_digest ~is_mainnet:false ~connection_id in
    "signed by " ^ Address.to_string (ok_exn (Signing.recover ~digest signature))
;;

(* Synthetic time for the strategy and the simulator, real time for the sockets in
   between: every step advances the clock 10ms and then lets I/O run for 1ms. *)
let drive time_source ~until =
  let rec loop n =
    if until ()
    then return ()
    else if n = 0
    then raise_s [%message "timed out driving the synthetic clock"]
    else (
      let%bind () =
        Time_source.advance_by_alarms_by time_source (Time_ns.Span.of_int_ms 10)
      in
      let%bind () = Scheduler.yield_until_no_jobs_remain () in
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 1) in
      loop (n - 1))
  in
  loop 5_000
;;

let%expect_test "HL_PRIVATE_KEY: signed quotes on hl-sim under a synthetic clock" =
  Log.Global.set_output [];
  let time_source = Time_source.create ~now:Session_helpers.start_time () in
  let now () = Time_ns.to_int_ns_since_epoch (Time_source.now time_source) in
  let journal_dir = Filename_unix.temp_dir "market-maker" "" in
  let journal_path = Filename.concat journal_dir "journal" in
  let%bind journal_writer = Writer.open_file journal_path in
  let server =
    Hl_sim.Server.create
      ~now
      ~journal:(Hl_sim.Journal.of_writer journal_writer)
      (Hl_sim.Adapt.create_exchange ())
  in
  let%bind http = Hl_sim.Server.listen server ~port:0 in
  let base_url =
    Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:(Hl_sim.Server.port http) ()
  in
  (* A static book 20 bps wide around 100000, placed unsigned for another account. *)
  let%bind response =
    Hl_client.Exchange.place_orders
      (Hl_client.Config.create ~address:maker ~base_url ())
      [ order ~is_buy:true ~px:"99900"; order ~is_buy:false ~px:"100100" ]
  in
  (match ok_exn response with
   | Ok (Order [ Resting _; Resting _ ]) -> ()
   | response -> raise_s [%message "static book" (response : Exchange_response.t)]);
  let (module Runner) =
    Venues.runner
      ~base_url
      ~getenv:(fun var -> Option.some_if (String.equal var "HL_PRIVATE_KEY") key_hex)
      Hyperliquid
      ~network:Local
    |> ok_exn
  in
  print_endline
    (String.substr_replace_all
       Runner.endpoint
       ~pattern:(Int.to_string (Hl_sim.Server.port http))
       ~with_:"PORT");
  [%expect
    {| http://127.0.0.1:PORT (account 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf, signed for testnet) |}];
  let account = Signing.Private_key.(address (ok_exn (of_hex key_hex))) in
  let stop = Ivar.create () in
  let outcome =
    Runner.connect_and_run
      ~time_source:(Time_source.read_only time_source)
      ?reload:None
      ?shadow_params:None
      ?strategy_log:None
      ?order_log:None
      ~symbol:(Exchange_core.Symbol.of_string "BTC")
      ~params:(fun instrument ~mid -> Ok (Mm_core.Params.for_instrument instrument ~mid))
      ~summary_interval:(Time_ns.Span.of_int_sec 60)
      ~stop:(Ivar.read stop)
  in
  let open_orders = ref [] in
  let%bind () =
    let rec poll () =
      let%bind orders =
        Hl_client.Info.open_orders (Hl_client.Config.create ~base_url ()) ~user:account
      in
      open_orders := ok_exn orders;
      if List.length !open_orders >= 6
      then return ()
      else Clock_ns.after (Time_ns.Span.of_int_ms 5) >>= poll
    in
    let polled = poll () in
    drive time_source ~until:(fun () -> Deferred.is_determined polled)
  in
  List.sort !open_orders ~compare:(fun (a : Open_order.t) b ->
    Price.descending a.limit_px b.limit_px)
  |> List.iter ~f:(fun (o : Open_order.t) ->
    printf
      "%s %s@%s\n"
      (Side.to_wire o.side)
      (Size.to_string o.sz)
      (Price.to_string o.limit_px));
  [%expect
    {|
    A 0.001@100070
    A 0.001@100050
    A 0.001@100030
    B 0.001@99970
    B 0.001@99950
    B 0.001@99930
    |}];
  Ivar.fill_exn stop ();
  let%bind () = drive time_source ~until:(fun () -> Deferred.is_determined outcome) in
  let%bind outcome in
  let outcome = ok_exn outcome in
  print_s
    [%message
      ""
        ~placed:(outcome.report.orders_placed > 0 : bool)
        ~mode:(outcome.report.mode : Mm_core.Strategy.Mode.t)];
  [%expect {| ((placed true) (mode Running)) |}];
  let%bind () = Cohttp_async.Server.close http in
  let%bind () = Writer.close journal_writer in
  let%bind lines = Reader.file_lines journal_path in
  let%bind () = Unix.unlink journal_path in
  let%bind () = Unix.rmdir journal_dir in
  let entries = List.map lines ~f:Hl_sim.Journal.Entry.of_line in
  (* The simulator stamped every request with the synthetic clock. *)
  let start = Time_ns.to_int_ns_since_epoch Session_helpers.start_time in
  print_s
    [%message
      ""
        ~synthetic_times:
          (List.for_all entries ~f:(fun e -> e.time >= start && e.time <= now ()) : bool)];
  [%expect {| (synthetic_times true) |}];
  List.map entries ~f:(fun entry ->
    ( Exchange_action.type_tag entry.request.action
    , Address.to_string entry.address
    , signer entry ))
  |> List.dedup_and_sort ~compare:[%compare: string * string * string]
  |> List.iter ~f:(fun (action, address, signer) ->
    printf "%s for %s, %s\n" action address signer);
  [%expect
    {|
    cancel for 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf, signed by 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf
    order for 0x00000000000000000000000000000000000000b0, unsigned
    order for 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf, signed by 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf
    |}];
  return ()
;;
