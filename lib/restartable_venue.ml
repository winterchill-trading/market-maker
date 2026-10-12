open! Core
open! Async

module Make (V : Mm_core.Venue.S) = struct
  type config = V.config

  (* What one live loop was handed. *)
  module Loop = struct
    type t =
      { fills_r : Mm_core.Fill.t Pipe.Reader.t
      ; fills_w : Mm_core.Fill.t Pipe.Writer.t
      ; updates_r : Mm_core.Order_update.t Pipe.Reader.t
      ; updates_w : Mm_core.Order_update.t Pipe.Writer.t
      ; mutable books : Exchange_core.L2.t Pipe.Reader.t list
      ; mutable reconnect_hooks : (unit -> unit) list
      }

    let create () =
      let fills_r, fills_w = Pipe.create () in
      let updates_r, updates_w = Pipe.create () in
      { fills_r; fills_w; updates_r; updates_w; books = []; reconnect_hooks = [] }
    ;;

    let detach t =
      Pipe.close t.fills_w;
      Pipe.close t.updates_w;
      List.iter t.books ~f:Pipe.close_read;
      t.reconnect_hooks <- []
    ;;
  end

  type t =
    { inner : V.t
    ; mutable loop : Loop.t
    ; mutable observers : (Strategy_input.t -> unit) list
    ; mutable order_observers : (Order_event.t -> unit) list
    }

  let observe t input = List.iter t.observers ~f:(fun f -> f input)
  let add_observer t f = t.observers <- t.observers @ [ f ]
  let observe_order t event = List.iter t.order_observers ~f:(fun f -> f event)
  let add_order_observer t f = t.order_observers <- t.order_observers @ [ f ]

  let forward t pipe ~writer ~input ~order_event =
    don't_wait_for
      (Pipe.iter_without_pushback pipe ~f:(fun x ->
         observe_order t (order_event x);
         Option.iter input ~f:(fun input -> observe t (input x));
         let w = writer t.loop in
         if not (Pipe.is_closed w) then Pipe.write_without_pushback w x))
  ;;

  let observed t result ~input =
    Result.iter result ~f:(fun x -> observe t (input x));
    result
  ;;

  let connect config =
    let%map.Deferred.Or_error inner = V.connect config in
    let t = { inner; loop = Loop.create (); observers = []; order_observers = [] } in
    forward
      t
      (V.fills inner)
      ~writer:(fun l -> l.fills_w)
      ~input:(Some (fun fill -> Strategy_input.Fill fill))
      ~order_event:(fun fill -> Order_event.Fill fill);
    forward
      t
      (V.order_updates inner)
      ~writer:(fun l -> l.updates_w)
      ~input:None
      ~order_event:(fun update -> Order_event.Update update);
    V.on_reconnect inner ~f:(fun () ->
      List.iter (List.rev t.loop.reconnect_hooks) ~f:(fun f -> f ()));
    t
  ;;

  let instrument t symbol = V.instrument t.inner symbol

  let books t symbol =
    let loop = t.loop in
    let%map reader = V.books t.inner symbol in
    loop.books <- reader :: loop.books;
    Pipe.map reader ~f:(fun book ->
      observe t (Book book);
      book)
  ;;

  let fills t = t.loop.fills_r
  let order_updates t = t.loop.updates_r

  let open_orders t symbol =
    V.open_orders t.inner symbol
    >>| observed t ~input:(fun orders -> Strategy_input.Open_orders orders)
  ;;

  let account t =
    V.account t.inner
    >>| observed t ~input:(fun account -> Strategy_input.Account account)
  ;;

  let place t requests =
    observe_order t (Place requests);
    let%map result = V.place t.inner requests in
    observe_order t (Placed { requests; result });
    result
  ;;

  let cancel t symbol order_ids =
    observe_order t (Cancel { symbol; order_ids });
    let%map result = V.cancel t.inner symbol order_ids in
    observe_order t (Cancelled { symbol; order_ids; result });
    result
  ;;

  let cancel_all t symbol =
    observe_order t (Cancel_all symbol);
    let%map result = V.cancel_all t.inner symbol in
    observe_order t (Cancelled_all { symbol; result });
    result
  ;;

  let on_reconnect t ~f = t.loop.reconnect_hooks <- f :: t.loop.reconnect_hooks
  let close _ = return ()

  let next_loop t =
    Loop.detach t.loop;
    t.loop <- Loop.create ()
  ;;

  let shutdown t =
    Loop.detach t.loop;
    V.close t.inner
  ;;
end
