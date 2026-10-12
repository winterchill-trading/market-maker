open! Core
open Exchange_core

module Resting = struct
  type t =
    { side : Side.t
    ; price : Price.t
    ; size : Size.t
    ; since_ns : int
    }
  [@@deriving sexp_of]
end

module Fill = struct
  type t =
    { local_ns : int
    ; side : Side.t
    ; price : Price.t
    ; size : Size.t
    ; maker : bool
    }
  [@@deriving sexp_of]
end

let max_fills = 8
let max_latencies = 200

type t =
  { venue : string option
  ; symbol : string option
  ; counts : int String.Map.t
  ; skipped : int
  ; resting : Resting.t String.Map.t
  ; position : Size.t
  ; volume : Usd.t
  ; fees : Usd.t
  ; recent_fills : Fill.t list
  ; pending_places : int String.Map.t (* client order id -> local time of the place *)
  ; latencies : int Fqueue.t
  ; last_ns : int option
  }
[@@deriving sexp_of]

let empty =
  { venue = None
  ; symbol = None
  ; counts = String.Map.empty
  ; skipped = 0
  ; resting = String.Map.empty
  ; position = Size.zero
  ; volume = Usd.zero
  ; fees = Usd.zero
  ; recent_fills = []
  ; pending_places = String.Map.empty
  ; latencies = Fqueue.empty
  ; last_ns = None
  }
;;

let venue t = t.venue
let symbol t = t.symbol
let resting t = t.resting
let position t = t.position
let volume t = t.volume
let fees t = t.fees
let recent_fills t = t.recent_fills
let count t event = Map.find t.counts event |> Option.value ~default:0
let last_ns t = t.last_ns

let ack_latency t =
  match Fqueue.to_list t.latencies |> List.sort ~compare:Int.compare with
  | [] -> None
  | sorted ->
    let n = List.length sorted in
    Some (n, List.nth_exn sorted (n / 2), List.last_exn sorted)
;;

let side_of_string = function
  | "buy" -> Some Side.Buy
  | "sell" -> Some Side.Sell
  | _ -> None
;;

let add_latency t latency =
  let latencies = Fqueue.enqueue t.latencies latency in
  let latencies =
    if Fqueue.length latencies > max_latencies
    then Fqueue.drop_exn latencies
    else latencies
  in
  { t with latencies }
;;

let remove_resting t order_id = { t with resting = Map.remove t.resting order_id }

let apply t ~local_ns ~event ~side ~price ~size ~order_id ~client_order_id ~status ~fee =
  match event with
  | "place" ->
    { t with
      pending_places = Map.set t.pending_places ~key:client_order_id ~data:local_ns
    }
  | "ack" ->
    let t =
      match Map.find t.pending_places client_order_id with
      | None -> t
      | Some placed ->
        add_latency
          { t with pending_places = Map.remove t.pending_places client_order_id }
          (local_ns - placed)
    in
    (match status, side, price, size with
     | "resting", Some side, Some price, Some size when not (String.is_empty order_id) ->
       { t with
         resting =
           Map.set
             t.resting
             ~key:order_id
             ~data:{ side; price; size; since_ns = local_ns }
       }
     | _ -> t)
  | "cancel_ack" when String.equal status "ok" -> remove_resting t order_id
  | "update" ->
    (match status with
     | "filled" | "cancelled" | "rejected" -> remove_resting t order_id
     | _ -> t)
  | "fill" ->
    (match side, price, size with
     | Some side, Some price, Some size ->
       let resting =
         Map.change t.resting order_id ~f:(function
           | None -> None
           | Some (r : Resting.t) ->
             let left = Size.(r.size - size) in
             if Size.(left <= zero) then None else Some { r with size = left })
       in
       { t with
         resting
       ; position = Size.(t.position + Mm_core.Fx.signed side size)
       ; volume = Usd.(t.volume + Mm_core.Fx.notional price size)
       ; fees = Usd.(t.fees + Option.value fee ~default:zero)
       ; recent_fills =
           List.take
             ({ Fill.local_ns; side; price; size; maker = String.equal status "maker" }
              :: t.recent_fills)
             max_fills
       }
     | _ -> t)
  | _ -> t
;;

let add_row t row =
  match row with
  | [ local_ts
    ; _venue_ts
    ; venue
    ; symbol
    ; event
    ; side
    ; price
    ; size
    ; order_id
    ; client_order_id
    ; status
    ; _trade_id
    ; fee
    ; _detail
    ] ->
    (match Int.of_string_opt local_ts with
     | None -> { t with skipped = t.skipped + 1 }
     | Some local_ns ->
       let t =
         { t with
           venue = Some venue
         ; symbol = Some symbol
         ; counts = Map.update t.counts event ~f:(fun n -> Option.value n ~default:0 + 1)
         ; last_ns = Some local_ns
         }
       in
       apply
         t
         ~local_ns
         ~event
         ~side:(side_of_string side)
         ~price:(Price.of_string_opt price)
         ~size:(Size.of_string_opt size)
         ~order_id
         ~client_order_id
         ~status
         ~fee:(Usd.of_string_opt fee))
  | _ -> { t with skipped = t.skipped + 1 }
;;

let side_name : Side.t -> string = function
  | Buy -> "buy"
  | Sell -> "sell"
;;

let ms ns = Float.of_int ns /. 1e6

let to_lines t ~now_ns =
  let header =
    sprintf
      "%s %s"
      (Option.value t.venue ~default:"-")
      (Option.value t.symbol ~default:"-")
  in
  let age =
    match t.last_ns with
    | None -> "no rows yet"
    | Some last -> sprintf "last row %.1fs ago" (Float.of_int (now_ns - last) /. 1e9)
  in
  let counts =
    List.map [ "place"; "ack"; "cancel"; "fill"; "update" ] ~f:(fun e ->
      sprintf "%s %d" e (count t e))
    |> String.concat ~sep:"  "
  in
  let latency =
    match ack_latency t with
    | None -> "ack latency -"
    | Some (n, median, max) ->
      sprintf "ack latency median %.2fms max %.2fms (last %d)" (ms median) (ms max) n
  in
  let book =
    let resting = Map.data t.resting in
    let side s =
      List.filter resting ~f:(fun (r : Resting.t) -> Side.equal r.side s)
      |> List.sort ~compare:(fun (a : Resting.t) b -> Price.compare b.price a.price)
    in
    List.map
      (side Sell @ side Buy)
      ~f:(fun (r : Resting.t) ->
        sprintf
          "  %-4s %s @ %s"
          (side_name r.side)
          (Size.to_string r.size)
          (Price.to_string r.price))
  in
  let fills =
    List.map t.recent_fills ~f:(fun (f : Fill.t) ->
      sprintf
        "  %.1fs ago  %-4s %s @ %s%s"
        (Float.of_int (now_ns - f.local_ns) /. 1e9)
        (side_name f.side)
        (Size.to_string f.size)
        (Price.to_string f.price)
        (if f.maker then "" else " (taker)"))
  in
  [ header ^ "  " ^ age
  ; sprintf
      "position %s  volume %s USD  fees %s USD"
      (Size.to_string t.position)
      (Usd.to_string t.volume)
      (Usd.to_string t.fees)
  ; counts
  ; latency
  ; sprintf "resting orders (%d)" (Map.length t.resting)
  ]
  @ book
  @ [ "recent fills" ]
  @ fills
;;
