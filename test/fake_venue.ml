open! Core
open! Async
open Exchange_core

type t =
  { time_source : Time_source.t
  ; place_delay : Time_ns.Span.t
  ; mutable orders : Open_order.t list
  ; mutable next_oid : int
  ; mutable next_tid : int
  ; mutable book_writers : L2.t Pipe.Writer.t list
  ; mutable last_book : L2.t option
  ; mutable reconnect_hooks : (unit -> unit) list
  ; fills_r : Mm_core.Fill.t Pipe.Reader.t
  ; fills_w : Mm_core.Fill.t Pipe.Writer.t
  ; updates_r : Mm_core.Order_update.t Pipe.Reader.t
  ; updates_w : Mm_core.Order_update.t Pipe.Writer.t
  ; mutable position : Size.t
  ; mutable closed : bool
  }

type config = t

let btc = Symbol.of_string "BTC"

let create
  ?(time_source = Time_source.wall_clock ())
  ?(place_delay = Time_ns.Span.zero)
  ()
  =
  let fills_r, fills_w = Pipe.create () in
  let updates_r, updates_w = Pipe.create () in
  { time_source
  ; place_delay
  ; orders = []
  ; next_oid = 0
  ; next_tid = 0
  ; book_writers = []
  ; last_book = None
  ; reconnect_hooks = []
  ; fills_r
  ; fills_w
  ; updates_r
  ; updates_w
  ; position = Size.zero
  ; closed = false
  }
;;

let connect t = return (Ok t)

let instrument _ symbol =
  return
    (Ok (Instrument.create symbol ~size_decimals:5 ~price_tick:Price.one ~max_leverage:40))
;;

let books t _ =
  let r, w = Pipe.create () in
  Option.iter t.last_book ~f:(Pipe.write_without_pushback w);
  t.book_writers <- w :: t.book_writers;
  return r
;;

let push_book t ~bid ~ask =
  let level px : L2.Level.t =
    { px = Price.of_string px; sz = Size.of_string "1"; n = 1 }
  in
  let time = Time_ns.to_int_ns_since_epoch (Time_source.now t.time_source) in
  let book = { L2.symbol = btc; time; bids = [ level bid ]; asks = [ level ask ] } in
  t.last_book <- Some book;
  t.book_writers <- List.filter t.book_writers ~f:(fun w -> not (Pipe.is_closed w));
  List.iter t.book_writers ~f:(fun w -> Pipe.write_without_pushback w book)
;;

let fills t = t.fills_r
let order_updates t = t.updates_r
let open_orders t _ = return (Ok t.orders)

let account _ =
  return
    (Ok
       { Account_view.account = Account.of_string "fake"
       ; balance = Usd.of_int 1000
       ; equity = Usd.of_int 1000
       ; total_notional = Usd.zero
       ; margin_used = Usd.zero
       ; maintenance_margin = Usd.zero
       ; available = Usd.of_int 1000
       ; positions = []
       ; time = 0
       })
;;

let place t requests =
  let%map () =
    if Time_ns.Span.(t.place_delay > zero)
    then Time_source.after t.time_source t.place_delay
    else return ()
  in
  Ok
    (List.map requests ~f:(fun (r : Order_request.t) : Order_status.t ->
       match r.px with
       | None -> Rejected (Unsupported "no market orders")
       | Some px ->
         t.next_oid <- t.next_oid + 1;
         let order_id = Order_id.of_int t.next_oid in
         t.orders
         <- t.orders
            @ [ { symbol = r.symbol
                ; side = r.side
                ; px
                ; size = r.size
                ; orig_size = Some r.size
                ; order_id
                ; client_order_id = r.client_order_id
                ; timestamp = 0
                }
              ];
         Resting { order_id; client_order_id = r.client_order_id }))
;;

let update t (o : Open_order.t) status =
  if not (Pipe.is_closed t.updates_w)
  then
    Pipe.write_without_pushback
      t.updates_w
      { Mm_core.Order_update.order_id = o.order_id
      ; client_order_id = o.client_order_id
      ; symbol = o.symbol
      ; side = o.side
      ; px = o.px
      ; status
      ; filled = Size.zero
      ; remaining = Size.zero
      ; time = 0
      }
;;

let cancel t _ oids =
  let gone, kept =
    List.partition_tf t.orders ~f:(fun o ->
      List.mem oids o.order_id ~equal:Order_id.equal)
  in
  t.orders <- kept;
  List.iter gone ~f:(fun o -> update t o Cancelled);
  return (Ok ())
;;

let cancel_all t symbol = cancel t symbol (List.map t.orders ~f:(fun o -> o.order_id))

let fill_best t (side : Side.t) =
  let best =
    List.filter t.orders ~f:(fun o -> Side.equal o.side side)
    |> List.max_elt ~compare:(fun (a : Open_order.t) b ->
      match side with
      | Buy -> Price.compare a.px b.px
      | Sell -> Price.compare b.px a.px)
  in
  Option.iter best ~f:(fun o ->
    t.orders
    <- List.filter t.orders ~f:(fun r -> not (Order_id.equal r.order_id o.order_id));
    t.next_tid <- t.next_tid + 1;
    t.position <- Size.(t.position + Mm_core.Fx.signed side o.size);
    update t o Filled;
    if not (Pipe.is_closed t.fills_w)
    then
      Pipe.write_without_pushback
        t.fills_w
        { Mm_core.Fill.trade_id = Trade_id.of_int t.next_tid
        ; order_id = o.order_id
        ; client_order_id = o.client_order_id
        ; symbol = o.symbol
        ; side
        ; px = o.px
        ; size = o.size
        ; fee = Usd.zero
        ; is_maker = true
        ; time = 0
        ; closed_pnl = None
        })
;;

let resting t = t.orders
let on_reconnect t ~f = t.reconnect_hooks <- f :: t.reconnect_hooks
let reconnect t = List.iter (List.rev t.reconnect_hooks) ~f:(fun f -> f ())

let close t =
  t.closed <- true;
  Pipe.close t.fills_w;
  Pipe.close t.updates_w;
  List.iter t.book_writers ~f:Pipe.close;
  return ()
;;

let closed t = t.closed
