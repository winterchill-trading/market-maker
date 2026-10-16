open! Core
open! Async
open Exchange_core
module Report = Mm_core.Live.Report
module Stats = Mm_core.Latency_histogram.Stats

module Outcome = struct
  type t =
    { report : Report.t
    ; tick_to_order : Stats.t option
    ; reloads : int
    ; shadow : Shadow.Stats.t option
    ; cycles : Cycle_monitor.Stats.t option
    ; plausibility : (string * int) list
    }
  [@@deriving sexp_of]

  let to_string_hum t =
    String.concat
      ~sep:"\n"
      ([ Report.to_string_hum t.report ]
       @ Option.value_map t.cycles ~default:[] ~f:(fun cycles ->
         [ sprintf "async cycles     %s" (Cycle_monitor.Stats.to_string_hum cycles) ])
       @ [ sprintf
             "tick-to-order    %s"
             (Option.value_map t.tick_to_order ~default:"-" ~f:Stats.to_string_hum)
         ]
       @ (if t.reloads > 0 then [ sprintf "params reloads   %d" t.reloads ] else [])
       @ Option.value_map t.shadow ~default:[] ~f:(fun (s : Shadow.Stats.t) ->
         [ sprintf "shadow plans     %d of %d differ" s.differing s.plans ])
       @
       match t.plausibility with
       | [] -> []
       | counts ->
         [ sprintf
             "plausibility     %s"
             (String.concat
                ~sep:", "
                (List.map counts ~f:(fun (name, n) -> sprintf "%s %d" name n)))
         ])
  ;;
end

(* How a plausibility event is counted in the outcome: the order log's [event] and
   [status] columns. *)
let plausibility_name : Mm_core.Strategy.Event.t -> string = function
  | Reference (Diverged _) -> "guard diverged"
  | Reference (Reference_jumped _) -> "guard reference_jumped"
  | Reference (Reference_missing _) -> "guard reference_missing"
  | Reference Resumed -> "guard resumed"
  | Toxicity (Widening _) -> "gate widening"
  | Toxicity (Pulled _) -> "gate pulled"
  | Toxicity Cleared -> "gate cleared"
;;

(* A gate or guard in the parameters with nothing to feed it is most likely a mistake: a
   guard pulling on a missing reference never quotes, a gate without a signal never acts. *)
let warn_unfed (params : Mm_core.Params.t) ~has_reference ~has_toxicity =
  if Option.is_some params.reference_guard && not has_reference
  then
    Log.Global.error
      "reference_guard is set but no reference source is configured (-reference)";
  if Option.is_some params.toxicity_gate && not has_toxicity
  then
    Log.Global.error
      "toxicity_gate is set but no toxicity source is configured (-toxicity-bucket)"
;;

let changed_fields (a : Mm_core.Params.t) (b : Mm_core.Params.t) =
  match Mm_core.Params.sexp_of_t a, Mm_core.Params.sexp_of_t b with
  | List a, List b ->
    List.filter b ~f:(fun field -> not (List.mem a field ~equal:Sexp.equal))
  | _ -> []
;;

module Make (V : Mm_core.Venue.S) = struct
  module Venue = Restartable_venue.Make (V)
  module Live = Mm_core.Live.Make (Venue)

  (* [`Stop] once [stop] is determined, else [`Reload] for each value on [reload]. *)
  let next_event ~stop ~reload =
    let reload_requested =
      match%bind Pipe.values_available reload with
      | `Eof -> Deferred.never ()
      | `Ok -> return ()
    in
    match%map
      choose
        [ choice stop (fun () -> `Stop); choice reload_requested (fun () -> `Reload) ]
    with
    | `Stop -> `Stop
    | `Reload ->
      if Deferred.is_determined stop
      then `Stop
      else (
        (* Several signals in a row make one reload. *)
        ignore
          (Pipe.read_now' reload : [ `Eof | `Nothing_available | `Ok of unit Queue.t ]);
        `Reload)
  ;;

  (* The shadow strategy, when there is one, and its current parameters. *)
  module Shadow_run = struct
    type t =
      { shadow : Shadow.t
      ; params : Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t
      ; mutable current : Mm_core.Params.t
      }

    let create ~params ~live ~instrument ~mid =
      let%map.Or_error current =
        Or_error.try_with_join (fun () -> params instrument ~mid)
        |> Or_error.tag ~tag:"shadow params"
      in
      { shadow = Shadow.create ~live ~shadow:current; params; current }
    ;;

    (* Re-reads the shadow parameters; updates both shadow strategies in place when they
       or the live ones changed. *)
    let reload t ~live ~live_changed ~instrument ~mid =
      let next =
        match Or_error.try_with_join (fun () -> t.params instrument ~mid) with
        | Ok next -> next
        | Error error ->
          Log.Global.error_s
            [%message
              "shadow params rejected, keeping the current ones" (error : Error.t)];
          t.current
      in
      if live_changed || not (Mm_core.Params.equal next t.current)
      then (
        if not (Mm_core.Params.equal next t.current)
        then
          Log.Global.info_s
            [%message
              "shadow params reloaded"
                ~changes:(changed_fields t.current next : Sexp.t list)];
        match Shadow.update_params t.shadow ~live ~shadow:next with
        | Ok () -> t.current <- next
        | Error error ->
          Log.Global.error_s
            [%message
              "shadow params update failed, keeping the current ones" (error : Error.t)])
    ;;
  end

  (* What the parameters callback builds before the loop starts: the observers that mirror
     the strategy see every input the loop sees, from its first snapshots on. *)
  module Prepared = struct
    type t =
      { instrument : Instrument.t
      ; mid : Price.t
      ; first_params : Mm_core.Params.t
      ; shadow : Shadow_run.t option
      ; log : Strategy_log.t option
      }

    let on_input t input ~now =
      Option.iter t.shadow ~f:(fun s -> Shadow.on_input s.shadow input ~now);
      Option.iter t.log ~f:(fun log -> Strategy_log.on_input log input ~now)
    ;;

    let on_resync t ~now =
      Option.iter t.shadow ~f:(fun s -> Shadow.on_resync s.shadow ~now);
      Option.iter t.log ~f:(fun log -> Strategy_log.on_resync log ~now)
    ;;
  end

  let connect_and_run
    ?(time_source = Time_source.wall_clock ())
    ?(reload = Pipe.empty ())
    ?shadow_params
    ?strategy_log
    ?order_log
    ?cycle_monitor
    ?reference
    ?toxicity
    config
    ~symbol
    ~params
    ~summary_interval
    ~stop
    =
    let now () = Time_ns.to_int_ns_since_epoch (Time_source.now time_source) in
    (* The log file opens before connecting, so that the log can start inside the
       parameters callback, before the loop takes its first snapshots. *)
    let%bind.Deferred.Or_error log_writer =
      match strategy_log with
      | None -> Deferred.Or_error.return None
      | Some path ->
        Monitor.try_with_or_error (fun () -> Writer.open_file path)
        >>| Or_error.map ~f:Option.some
    in
    let%bind.Deferred.Or_error order_log =
      match (order_log : Order_log.Spec.t option) with
      | None -> Deferred.Or_error.return None
      | Some { path; venue } ->
        Monitor.try_with_or_error (fun () -> Writer.open_file path)
        >>| Or_error.map ~f:(fun writer ->
          Some (writer, Order_log.create writer ~venue ~now))
    in
    let venue = ref None in
    let prepared = ref None in
    let on_venue v =
      venue := Some v;
      Option.iter order_log ~f:(fun (_, log) ->
        Venue.add_order_observer v (Order_log.on_event log));
      Venue.add_observer v (fun input ->
        Option.iter !prepared ~f:(fun p -> Prepared.on_input p input ~now:(now ())))
    in
    let params_and_observers instrument ~mid =
      let open Or_error.Let_syntax in
      let%bind first_params = Or_error.try_with_join (fun () -> params instrument ~mid) in
      let%map shadow =
        match shadow_params with
        | None -> return None
        | Some params ->
          Shadow_run.create ~params ~live:first_params ~instrument ~mid >>| Option.some
      in
      let log =
        Option.map log_writer ~f:(fun writer ->
          Strategy_log.of_file_writer writer ~params:first_params)
      in
      prepared := Some { Prepared.instrument; mid; first_params; shadow; log };
      first_params
    in
    let close_log () =
      let%bind () = Option.value_map log_writer ~default:(return ()) ~f:Writer.close in
      Option.value_map order_log ~default:(return ()) ~f:(fun (writer, _) ->
        Writer.close writer)
    in
    (* The loop closes the venue on every path, but closing a {!Restartable_venue} does
       nothing: the connection goes down here. *)
    let shutdown () =
      let%bind () = Option.value_map !venue ~default:(return ()) ~f:Venue.shutdown in
      close_log ()
    in
    match%bind
      Live.connect_and_start
        ~time_source
        ~on_venue
        config
        ~symbol
        ~params:params_and_observers
        ~summary_interval
    with
    | Error error ->
      let%map () = shutdown () in
      Error error
    | Ok live ->
      let ({ Prepared.instrument; mid; first_params; shadow; log = strategy_log } as
           prepared)
        =
        Option.value_exn !prepared
      in
      (* Mirror strategies start the same action rate grace period as the loop's own on
         every venue reconnect. *)
      Live.on_resync live ~f:(fun () -> Prepared.on_resync prepared ~now:(now ()));
      let log_event event =
        Option.iter order_log ~f:(fun (_, log) -> Order_log.on_event log event)
      in
      let plausibility = String.Table.create () in
      Live.on_strategy_event live ~f:(fun event ->
        Hashtbl.incr plausibility (plausibility_name event);
        log_event (Plausibility { symbol; event }));
      let has_reference = Option.is_some reference
      and has_toxicity = Option.is_some toxicity in
      warn_unfed first_params ~has_reference ~has_toxicity;
      let stopping = ref false in
      (* Reference mids and toxicity measurements go to the loop and, like the venue's
         inputs, to the mirrors, stamped with the same time. *)
      Option.iter reference ~f:(fun reference ->
        don't_wait_for
          (Pipe.iter_without_pushback reference ~f:(fun mid ->
             if not !stopping
             then (
               let time = now () in
               Live.on_reference live mid;
               Prepared.on_input prepared (Reference { time; mid }) ~now:time))));
      Option.iter toxicity ~f:(fun toxicity ->
        don't_wait_for
          (Pipe.iter_without_pushback
             toxicity
             ~f:(fun ({ signal; imbalance } : Toxicity_source.Signal.t) ->
               if not !stopping
               then (
                 let time = now () in
                 Live.on_toxicity live ~signal ~imbalance;
                 Prepared.on_input
                   prepared
                   (Toxicity { time; signal; imbalance })
                   ~now:time;
                 (* The decision this measurement leads to, computed as the strategy's
                    next tick will: the loop ticks on its sequencer, later. *)
                 let decision =
                   match (Mm_core.Strategy.params (Live.strategy live)).toxicity_gate with
                   | None -> Mm_core.Toxicity_gate.Decision.Normal
                   | Some config ->
                     Mm_core.Toxicity_gate.decide
                       config
                       ~now:time
                       (Some { value = signal; imbalance; time })
                 in
                 log_event (Toxicity { symbol; signal; imbalance; decision })))));
      let status_stop = Ivar.create () in
      Option.iter cycle_monitor ~f:(fun monitor ->
        Cycle_monitor.start monitor;
        Time_source.every
          time_source
          ~stop:(Ivar.read status_stop)
          ~continue_on_error:false
          summary_interval
          (fun () ->
             Log.Global.info_s
               [%message
                 "status"
                   ~async_cycles:
                     (Cycle_monitor.Stats.to_string_hum (Cycle_monitor.stats monitor)
                      : string)]));
      let finish ~reloads live =
        Ivar.fill_if_empty status_stop ();
        stopping := true;
        Option.iter reference ~f:Pipe.close_read;
        Option.iter toxicity ~f:Pipe.close_read;
        let%bind report = Live.stop live in
        Option.iter cycle_monitor ~f:Cycle_monitor.stop;
        let tick_to_order = Live.tick_to_order live in
        let%map () = shutdown () in
        Ok
          { Outcome.report
          ; tick_to_order
          ; reloads
          ; shadow = Option.map shadow ~f:(fun s -> Shadow.stats s.shadow)
          ; cycles = Option.map cycle_monitor ~f:Cycle_monitor.stats
          ; plausibility =
              Hashtbl.to_alist plausibility |> List.sort ~compare:[%compare: string * int]
          }
      in
      let reload_shadow ~live ~live_changed =
        Option.iter shadow ~f:(fun shadow ->
          Shadow_run.reload shadow ~live ~live_changed ~instrument ~mid)
      in
      let keep_current ~current error =
        Log.Global.error_s
          [%message "params rejected, keeping the current ones" (error : Error.t)];
        reload_shadow ~live:current ~live_changed:false
      in
      let rec loop live ~current ~reloads =
        match%bind next_event ~stop ~reload with
        | `Stop -> finish ~reloads live
        | `Reload ->
          (match Or_error.try_with_join (fun () -> params instrument ~mid) with
           | Error error ->
             keep_current ~current error;
             loop live ~current ~reloads
           | Ok next when Mm_core.Params.equal next current ->
             Log.Global.info "params reload: nothing changed";
             reload_shadow ~live:current ~live_changed:false;
             loop live ~current ~reloads
           | Ok next ->
             (* The running loop swaps the parameters in place: no restart, no cancel-all;
                the next tick requotes. *)
             (match Live.update_params live next with
              | Error error ->
                keep_current ~current error;
                loop live ~current ~reloads
              | Ok () ->
                Log.Global.info_s
                  [%message
                    "params reloaded" ~changes:(changed_fields current next : Sexp.t list)];
                warn_unfed next ~has_reference ~has_toxicity;
                reload_shadow ~live:next ~live_changed:true;
                Option.iter strategy_log ~f:(fun log ->
                  match Strategy_log.update_params log next with
                  | Ok () -> ()
                  | Error error ->
                    Log.Global.error_s
                      [%message "strategy log: params update failed" (error : Error.t)]);
                loop live ~current:next ~reloads:(reloads + 1)))
      in
      loop live ~current:first_params ~reloads:0
  ;;
end
