open! Core
open! Async
open Exchange_core

module Uri_sexp = struct
  type t = Uri.t [@@deriving equal]

  let sexp_of_t uri = Sexp.Atom (Uri.to_string uri)
end

module Spec = struct
  type t =
    | Anchor
    | Feed of
        { venue : string
        ; symbol : string
        ; base_url : Uri_sexp.t option
        }
  [@@deriving sexp_of, equal]

  let venues = [ "hyperliquid"; "binance"; "bybit" ]

  let of_string s =
    match String.lsplit2 s ~on:':' with
    | None when String.equal (String.lowercase s) "anchor" -> Ok Anchor
    | None ->
      Or_error.error_s
        [%message "expected anchor or <venue>:<symbol>[@<base url>]" ~reference:s]
    | Some (venue, rest) ->
      let venue = String.lowercase venue in
      let venue = if String.equal venue "hl" then "hyperliquid" else venue in
      let symbol, base_url =
        match String.lsplit2 rest ~on:'@' with
        | None -> rest, None
        | Some (symbol, url) -> symbol, Some (Uri.of_string url)
      in
      if not (List.mem venues venue ~equal:String.equal)
      then
        Or_error.error_s
          [%message "unknown reference venue" venue ~expected:(venues : string list)]
      else if String.is_empty symbol
      then Or_error.error_s [%message "missing reference symbol" ~reference:s]
      else Ok (Feed { venue; symbol; base_url })
  ;;

  let to_string = function
    | Anchor -> "anchor"
    | Feed { venue; symbol; base_url = None } -> sprintf "%s:%s" venue symbol
    | Feed { venue; symbol; base_url = Some url } ->
      sprintf "%s:%s@%s" venue symbol (Uri.to_string url)
  ;;

  let arg_type = Command.Arg_type.create (fun s -> ok_exn (of_string s))
end

module Anchor_status = struct
  type t =
    { symbol : string
    ; fresh : bool
    ; reference_price : Price.t option
    }
  [@@deriving sexp_of, equal]

  let field name = function
    | `Assoc fields -> List.Assoc.find fields name ~equal:String.equal
    | _ -> None
  ;;

  let string_field name json =
    match field name json with
    | Some (`String s) -> Some s
    | _ -> None
  ;;

  (* hl-sim names an anchor by its spec, [binance:BTCUSDT=BTC] or [hyperliquid:BTC]; the
     other simulators give the simulated symbol in its own field. *)
  let symbol json =
    match string_field "sim_symbol" json, string_field "symbol" json with
    | Some s, _ | None, Some s -> Some s
    | None, None ->
      Option.bind (string_field "anchor" json) ~f:(fun spec ->
        match String.rsplit2 spec ~on:'=' with
        | Some (_, coin) -> Some coin
        | None -> Option.map (String.rsplit2 spec ~on:':') ~f:snd)
  ;;

  let fresh json =
    match field "fresh" json, string_field "state" json with
    | Some (`Bool fresh), _ -> Some fresh
    | None, Some state -> Some (String.equal state "fresh")
    | _ -> None
  ;;

  let entry json =
    let%map.Option symbol = symbol json
    and fresh = fresh json in
    let reference_price =
      Option.bind (string_field "reference_price" json) ~f:Price.of_string_opt
    in
    { symbol; fresh; reference_price }
  ;;

  let of_json (json : Yojson.Safe.t) =
    let entries =
      match json with
      | `List entries -> entries
      | json ->
        (match field "anchors" json with
         | Some (`List entries) -> entries
         | _ -> [])
    in
    List.filter_map entries ~f:entry
  ;;

  let reference ts ~symbol =
    List.find_map ts ~f:(fun t ->
      if t.fresh && String.equal t.symbol symbol then t.reference_price else None)
  ;;
end

let fetch_status status_url =
  Monitor.try_with_or_error (fun () ->
    let%bind response, body = Cohttp_async.Client.get status_url in
    let%map body = Cohttp_async.Body.to_string body in
    match Cohttp.Response.status response with
    | `OK -> Anchor_status.of_json (Yojson.Safe.from_string body)
    | status ->
      raise_s
        [%message "status request failed" ~status:(Cohttp.Code.string_of_status status)])
;;

let of_anchor_status
  ?(interval = Time_ns.Span.of_int_ms 500)
  ?(time_source = Time_source.wall_clock ())
  ~status_url
  ~symbol
  ()
  =
  Pipe.create_reader ~close_on_exception:false (fun writer ->
    Deferred.repeat_until_finished () (fun () ->
      if Pipe.is_closed writer
      then return (`Finished ())
      else (
        let%bind () =
          match%map fetch_status status_url with
          | Error error ->
            Log.Global.debug_s
              [%message
                "reference: anchor status unavailable"
                  ~url:(Uri.to_string status_url)
                  (error : Error.t)]
          | Ok anchors ->
            Option.iter (Anchor_status.reference anchors ~symbol) ~f:(fun price ->
              Pipe.write_without_pushback_if_open writer price)
        in
        let%map () =
          Deferred.any_unit [ Time_source.after time_source interval; Pipe.closed writer ]
        in
        `Repeat ())))
;;

let of_feed (feed : Market_data.Feed.t) =
  let module F = (val feed) in
  Pipe.close_read F.trades;
  Pipe.close_read F.l2;
  Pipe.close_read F.funding;
  let mids =
    Pipe.filter_map F.bbo ~f:(fun (bbo : Market_data.Bbo.t) ->
      Option.some_if
        Price.(bbo.bid_price > zero && bbo.ask_price >= bbo.bid_price)
        (Market_data.Bbo.mid bbo))
  in
  don't_wait_for
    (let%bind () = Pipe.closed mids in
     F.close ());
  mids
;;
