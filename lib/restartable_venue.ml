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
    }

  let forward t pipe ~writer =
    don't_wait_for
      (Pipe.iter_without_pushback pipe ~f:(fun x ->
         let w = writer t.loop in
         if not (Pipe.is_closed w) then Pipe.write_without_pushback w x))
  ;;

  let connect config =
    let%map.Deferred.Or_error inner = V.connect config in
    let t = { inner; loop = Loop.create () } in
    forward t (V.fills inner) ~writer:(fun l -> l.fills_w);
    forward t (V.order_updates inner) ~writer:(fun l -> l.updates_w);
    V.on_reconnect inner ~f:(fun () ->
      List.iter (List.rev t.loop.reconnect_hooks) ~f:(fun f -> f ()));
    t
  ;;

  let instrument t symbol = V.instrument t.inner symbol

  let books t symbol =
    let loop = t.loop in
    let%map reader = V.books t.inner symbol in
    loop.books <- reader :: loop.books;
    reader
  ;;

  let fills t = t.loop.fills_r
  let order_updates t = t.loop.updates_r
  let open_orders t symbol = V.open_orders t.inner symbol
  let account t = V.account t.inner
  let place t orders = V.place t.inner orders
  let cancel t symbol oids = V.cancel t.inner symbol oids
  let cancel_all t symbol = V.cancel_all t.inner symbol
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
