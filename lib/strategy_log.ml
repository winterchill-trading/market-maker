open! Core
open! Async

module Event = struct
  type t =
    | Params of Mm_core.Params.t
    | Input of Strategy_input.t
    | Tick of
        { now : int
        ; plan : Mm_core.Action.t list
        }
  [@@deriving sexp, compare, equal]
end

type t =
  { write : Event.t -> unit
  ; close : unit -> unit Deferred.t
  ; mutable strategy : Mm_core.Strategy.t
  }

let of_writer' write ~close ~params =
  write (Event.Params params);
  { write; close; strategy = Mm_core.Strategy.create params }
;;

let of_writer write ~params = of_writer' write ~close:(fun () -> return ()) ~params

let create path ~params =
  let%map writer = Writer.open_file path in
  of_writer'
    (fun event ->
      Writer.write_sexp writer (Event.sexp_of_t event);
      Writer.newline writer)
    ~close:(fun () -> Writer.close writer)
    ~params
;;

let on_input t input ~now =
  t.write (Input input);
  let strategy, plan =
    Mm_core.Strategy.tick (Strategy_input.apply t.strategy input) ~now
  in
  t.strategy <- strategy;
  t.write (Tick { now; plan })
;;

let restart t ~params =
  t.write (Params params);
  t.strategy <- Mm_core.Strategy.create params
;;

let close t = t.close ()

let load path =
  Monitor.try_with_or_error (fun () -> Reader.load_sexps_exn path Event.t_of_sexp)
;;

module Replay = struct
  type mismatch =
    { line : int
    ; now : int
    ; logged : Mm_core.Action.t list
    ; replayed : Mm_core.Action.t list
    }
  [@@deriving sexp_of]

  type t =
    { ticks : int
    ; plans : int
    ; mismatches : mismatch list
    }
  [@@deriving sexp_of]

  let run events =
    match events with
    | [] | (Event.Input _ | Tick _) :: _ ->
      Or_error.error_string "a strategy log starts with a Params line"
    | Params _ :: _ ->
      Or_error.try_with (fun () ->
        let _strategy, result =
          List.foldi
            events
            ~init:(None, { ticks = 0; plans = 0; mismatches = [] })
            ~f:(fun i (strategy, acc) event ->
              match event, strategy with
              | Params params, _ -> Some (Mm_core.Strategy.create params), acc
              | (Input _ | Tick _), None -> assert false (* the log starts with Params *)
              | Input input, Some strategy ->
                Some (Strategy_input.apply strategy input), acc
              | Tick { now; plan }, Some strategy ->
                let strategy, replayed = Mm_core.Strategy.tick strategy ~now in
                let acc =
                  { ticks = acc.ticks + 1
                  ; plans = (acc.plans + if List.is_empty plan then 0 else 1)
                  ; mismatches =
                      (if List.equal Mm_core.Action.equal plan replayed
                       then acc.mismatches
                       else
                         { line = i + 1; now; logged = plan; replayed } :: acc.mismatches)
                  }
                in
                Some strategy, acc)
        in
        { result with mismatches = List.rev result.mismatches })
  ;;
end
