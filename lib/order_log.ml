open! Core
open! Async
open Exchange_core

module Spec = struct
  type t =
    { path : string
    ; venue : string
    }
end

type t =
  { writer : Writer.t
  ; venue : string
  ; now : unit -> int
  }

let columns =
  [ "local_ts"
  ; "venue_ts"
  ; "venue"
  ; "symbol"
  ; "event"
  ; "side"
  ; "price"
  ; "size"
  ; "order_id"
  ; "client_order_id"
  ; "status"
  ; "trade_id"
  ; "fee"
  ; "detail"
  ]
;;

let header = String.concat ~sep:"," columns

let quote field =
  if String.exists field ~f:(function
       | ',' | '"' | '\n' | '\r' -> true
       | _ -> false)
  then "\"" ^ String.substr_replace_all field ~pattern:"\"" ~with_:"\"\"" ^ "\""
  else field
;;

module Row = struct
  type t =
    { venue_ts : int option
    ; symbol : Symbol.t
    ; event : string
    ; side : Side.t option
    ; price : Price.t option
    ; size : Size.t option
    ; order_id : Order_id.t option
    ; client_order_id : Client_order_id.t option
    ; status : string
    ; trade_id : Trade_id.t option
    ; fee : Usd.t option
    ; detail : string
    }

  let create
    ?venue_ts
    ?side
    ?price
    ?size
    ?order_id
    ?client_order_id
    ?(status = "")
    ?trade_id
    ?fee
    ?(detail = "")
    symbol
    event
    =
    { venue_ts
    ; symbol
    ; event
    ; side
    ; price
    ; size
    ; order_id
    ; client_order_id
    ; status
    ; trade_id
    ; fee
    ; detail
    }
  ;;

  let side_name : Side.t -> string = function
    | Buy -> "buy"
    | Sell -> "sell"
  ;;

  let to_csv t ~venue ~local_ts =
    let opt f = Option.value_map ~default:"" ~f in
    [ Int.to_string local_ts
    ; opt Int.to_string t.venue_ts
    ; venue
    ; Symbol.to_string t.symbol
    ; t.event
    ; opt side_name t.side
    ; opt Price.to_string t.price
    ; opt Size.to_string t.size
    ; opt Order_id.to_string t.order_id
    ; opt Client_order_id.to_string t.client_order_id
    ; t.status
    ; opt Trade_id.to_string t.trade_id
    ; opt Usd.to_string t.fee
    ; t.detail
    ]
    |> List.map ~f:quote
    |> String.concat ~sep:","
  ;;
end

let error_detail error = Error.to_string_hum error

let request_row event ?status ?order_id ?detail (r : Order_request.t) =
  Row.create
    r.symbol
    event
    ~side:r.side
    ?price:r.px
    ~size:r.size
    ?client_order_id:r.client_order_id
    ?status
    ?order_id
    ?detail
;;

let ack_row (r : Order_request.t) (status : Order_status.t) =
  match status with
  | Resting { order_id; client_order_id = _ } ->
    request_row "ack" r ~status:"resting" ~order_id
  | Filled { order_id; total; avg_px; client_order_id = _ } ->
    request_row
      "ack"
      r
      ~status:"filled"
      ~order_id
      ~detail:(sprintf "filled %s at %s" (Size.to_string total) (Price.to_string avg_px))
  | Rejected reason ->
    request_row
      "ack"
      r
      ~status:"rejected"
      ~detail:(Sexp.to_string [%sexp (reason : Reject_reason.t)])
;;

let update_status : Mm_core.Order_update.Status.t -> string = function
  | New -> "new"
  | Partially_filled -> "partially_filled"
  | Filled -> "filled"
  | Cancelled -> "cancelled"
  | Rejected -> "rejected"
;;

(* Plausibility rows: [status] names what happened, [price] is the reference mid where
   there is one, [detail] lists the numbers as [key=value] pairs. *)
let kv pairs =
  String.concat ~sep:" " (List.map pairs ~f:(fun (k, v) -> sprintf "%s=%s" k v))
;;

let bps x = sprintf "%.2f" x
let ratio x = sprintf "%.4f" x

let guard_row symbol : Mm_core.Reference_guard.Event.t -> Row.t = function
  | Diverged { divergence_bps; held_ms; venue_mid; reference_mid } ->
    Row.create
      symbol
      "guard"
      ~status:"diverged"
      ~price:reference_mid
      ~detail:
        (kv
           [ "divergence_bps", bps divergence_bps
           ; "held_ms", Int.to_string held_ms
           ; "venue_mid", Price.to_string venue_mid
           ])
  | Reference_jumped { from_; to_; jump_bps } ->
    Row.create
      symbol
      "guard"
      ~status:"reference_jumped"
      ~price:to_
      ~detail:(kv [ "from", Price.to_string from_; "jump_bps", bps jump_bps ])
  | Reference_missing { age_ms } ->
    Row.create
      symbol
      "guard"
      ~status:"reference_missing"
      ~detail:
        (match age_ms with
         | None -> "no reference yet"
         | Some age_ms -> kv [ "age_ms", Int.to_string age_ms ])
  | Resumed -> Row.create symbol "guard" ~status:"resumed"
;;

let gate_row symbol : Mm_core.Toxicity_gate.Event.t -> Row.t = function
  | Widening { signal } ->
    Row.create symbol "gate" ~status:"widening" ~detail:(kv [ "signal", ratio signal ])
  | Pulled { signal } ->
    Row.create symbol "gate" ~status:"pulled" ~detail:(kv [ "signal", ratio signal ])
  | Cleared -> Row.create symbol "gate" ~status:"cleared"
;;

let decision_fields : Mm_core.Toxicity_gate.Decision.t -> string * (string * string) list
  = function
  | Normal -> "normal", []
  | Widen { intensity; extra_half_spread_bps; reservation_shift_bps; size_factor } ->
    ( "widen"
    , [ "intensity", ratio intensity
      ; "extra_half_spread_bps", bps extra_half_spread_bps
      ; "shift_bps", bps reservation_shift_bps
      ; "size_factor", ratio size_factor
      ] )
  | Pull { signal = _ } -> "pull", []
;;

let plausibility_rows : Order_event.t -> Row.t list = function
  | Plausibility { symbol; event = Reference e } -> [ guard_row symbol e ]
  | Plausibility { symbol; event = Toxicity e } -> [ gate_row symbol e ]
  | Toxicity { symbol; signal; imbalance; decision } ->
    let status, fields = decision_fields decision in
    [ Row.create
        symbol
        "toxicity"
        ~status
        ~detail:(kv ([ "signal", ratio signal; "imbalance", ratio imbalance ] @ fields))
    ]
  | Place _
  | Placed _
  | Cancel _
  | Cancelled _
  | Cancel_all _
  | Cancelled_all _
  | Update _
  | Fill _ -> []
;;

let event_rows : Order_event.t -> Row.t list = function
  | Place requests -> List.map requests ~f:(request_row "place")
  | Placed { requests; result = Ok statuses } ->
    (match List.zip requests statuses with
     | Ok pairs -> List.map pairs ~f:(fun (r, status) -> ack_row r status)
     | Unequal_lengths ->
       List.map requests ~f:(fun r ->
         request_row
           "ack"
           r
           ~status:"error"
           ~detail:
             (sprintf
                "%d statuses for %d requests"
                (List.length statuses)
                (List.length requests))))
  | Placed { requests; result = Error error } ->
    List.map requests ~f:(request_row "ack" ~status:"error" ~detail:(error_detail error))
  | Cancel { symbol; order_ids } ->
    List.map order_ids ~f:(fun order_id -> Row.create symbol "cancel" ~order_id)
  | Cancelled { symbol; order_ids; result } ->
    let status, detail =
      match result with
      | Ok () -> "ok", ""
      | Error error -> "error", error_detail error
    in
    List.map order_ids ~f:(fun order_id ->
      Row.create symbol "cancel_ack" ~order_id ~status ~detail)
  | Cancel_all symbol -> [ Row.create symbol "cancel_all" ]
  | Cancelled_all { symbol; result = Ok () } ->
    [ Row.create symbol "cancel_all_ack" ~status:"ok" ]
  | Cancelled_all { symbol; result = Error error } ->
    [ Row.create symbol "cancel_all_ack" ~status:"error" ~detail:(error_detail error) ]
  | Update u ->
    [ Row.create
        u.symbol
        "update"
        ~venue_ts:u.time
        ~side:u.side
        ~price:u.px
        ~size:u.remaining
        ~order_id:u.order_id
        ?client_order_id:u.client_order_id
        ~status:(update_status u.status)
        ~detail:(sprintf "filled %s" (Size.to_string u.filled))
    ]
  | Fill f ->
    [ Row.create
        f.symbol
        "fill"
        ~venue_ts:f.time
        ~side:f.side
        ~price:f.px
        ~size:f.size
        ~order_id:f.order_id
        ?client_order_id:f.client_order_id
        ~status:(if f.is_maker then "maker" else "taker")
        ~trade_id:f.trade_id
        ~fee:f.fee
    ]
  | (Plausibility _ | Toxicity _) as event -> plausibility_rows event
;;

let rows ~venue ~local_ts event =
  List.map (event_rows event) ~f:(Row.to_csv ~venue ~local_ts)
;;

let parse_line line =
  let fields = ref [] in
  let field = Buffer.create 32 in
  let finish () =
    fields := Buffer.contents field :: !fields;
    Buffer.clear field
  in
  let n = String.length line in
  (* [quoted]: inside a quoted field. *)
  let rec loop i ~quoted =
    if i >= n
    then finish ()
    else (
      match line.[i], quoted with
      | '"', true when i + 1 < n && Char.equal line.[i + 1] '"' ->
        Buffer.add_char field '"';
        loop (i + 2) ~quoted
      | '"', true -> loop (i + 1) ~quoted:false
      | '"', false when Buffer.length field = 0 -> loop (i + 1) ~quoted:true
      | ',', false ->
        finish ();
        loop (i + 1) ~quoted
      | c, _ ->
        Buffer.add_char field c;
        loop (i + 1) ~quoted)
  in
  loop 0 ~quoted:false;
  List.rev !fields
;;

let create writer ~venue ~now =
  Writer.write_line writer header;
  { writer; venue; now }
;;

let on_event t event =
  let local_ts = t.now () in
  List.iter (rows ~venue:t.venue ~local_ts event) ~f:(Writer.write_line t.writer)
;;
