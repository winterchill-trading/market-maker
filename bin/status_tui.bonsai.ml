open! Core
open! Async
open Market_maker

let now_ns () = Time_ns.to_int_ns_since_epoch (Time_ns.now ())

let app var ~exit ~dimensions (local_ _graph) =
  let open Bonsai_term in
  let view =
    Bonsai.map2
      (Bonsai.Expert.Var.value var)
      dimensions
      ~f:(fun (status, now_ns) (dimensions : Dimensions.t) ->
        let lines = Order_log_status.to_lines status ~now_ns in
        let title, rest =
          match lines with
          | [] -> "", []
          | title :: rest -> title, rest
        in
        View.vcat
          ([ View.text ~attrs:[ Attr.bold ] ("market-maker  " ^ title) ]
           @ List.map rest ~f:(fun line ->
             if String.is_prefix line ~prefix:" "
             then View.text line
             else View.text ~attrs:[ Attr.bold ] line)
           @ [ View.text ""; View.text "q to quit" ])
        |> View.crop ~b:(Int.max 0 (List.length lines + 2 - dimensions.height)))
  in
  let handler =
    Bonsai.return (fun (event : Event.t) ->
      match event with
      | Key_press { key = ASCII ('q' | 'Q'); mods = _ }
      | Key_press { key = ASCII ('c' | 'C'); mods = [ Ctrl ] } -> exit ()
      | _ -> Effect.Ignore)
  in
  ~view, ~handler
;;

let available = true

let run tail status ~refresh =
  let var = Bonsai.Expert.Var.create (status, now_ns ()) in
  let stop = Ivar.create () in
  Clock_ns.every' ~stop:(Ivar.read stop) refresh (fun () ->
    let status, _ = Bonsai.Expert.Var.get var in
    let%map status = Order_log_tail.update tail status in
    Bonsai.Expert.Var.set var (status, now_ns ()));
  let%map result = Bonsai_term.start_with_exit (app var) in
  Ivar.fill_if_empty stop ();
  result
;;
