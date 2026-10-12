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
    }
  [@@deriving sexp_of]

  let to_string_hum t =
    String.concat
      ~sep:"\n"
      ([ Report.to_string_hum t.report
       ; sprintf
           "tick-to-order    %s"
           (Option.value_map t.tick_to_order ~default:"-" ~f:Stats.to_string_hum)
       ]
       @ (if t.reloads > 0 then [ sprintf "params reloads   %d" t.reloads ] else [])
       @ Option.value_map t.shadow ~default:[] ~f:(fun (s : Shadow.Stats.t) ->
         [ sprintf "shadow plans     %d of %d differ" s.differing s.plans ]))
  ;;
end

let changed_fields (a : Mm_core.Params.t) (b : Mm_core.Params.t) =
  match Mm_core.Params.sexp_of_t a, Mm_core.Params.sexp_of_t b with
  | List a, List b ->
    List.filter b ~f:(fun field -> not (List.mem a field ~equal:Sexp.equal))
  | _ -> []
;;

module Make (V : Mm_core.Venue.S) = struct
  module Venue = Restartable_venue.Make (V)
  module Live = Mm_core.Live.Make (Venue)

  let prepare ?time_source venue ~symbol ~params =
    let open Deferred.Or_error.Let_syntax in
    let%bind instrument = Venue.instrument venue symbol in
    let%bind mid = Live.first_mid ?time_source venue symbol in
    let%map params =
      Deferred.return (Or_error.try_with_join (fun () -> params instrument ~mid))
    in
    instrument, mid, params
  ;;

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

    let create venue ~time_source ~params ~live ~instrument ~mid =
      let%map.Or_error current =
        Or_error.try_with_join (fun () -> params instrument ~mid)
        |> Or_error.tag ~tag:"shadow params"
      in
      let shadow = Shadow.create ~live ~shadow:current in
      Venue.add_observer venue (fun input ->
        Shadow.on_input
          shadow
          input
          ~now:(Time_ns.to_int_ns_since_epoch (Time_source.now time_source)));
      { shadow; params; current }
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

  let connect_and_run
    ?(time_source = Time_source.wall_clock ())
    ?(reload = Pipe.empty ())
    ?shadow_params
    ?strategy_log
    config
    ~symbol
    ~params
    ~summary_interval
    ~stop
    =
    let%bind.Deferred.Or_error venue = Venue.connect config in
    let fail error =
      let%map () = Venue.shutdown venue in
      Error error
    in
    let start params =
      Live.start ~time_source venue { Mm_core.Live.Config.params; summary_interval }
    in
    let prepared =
      let open Deferred.Or_error.Let_syntax in
      let%bind instrument, mid, first_params =
        prepare ~time_source venue ~symbol ~params
      in
      let%map shadow =
        match shadow_params with
        | None -> return None
        | Some params ->
          Shadow_run.create venue ~time_source ~params ~live:first_params ~instrument ~mid
          |> Or_error.map ~f:Option.some
          |> Deferred.return
      in
      instrument, mid, first_params, shadow
    in
    match%bind prepared with
    | Error error -> fail error
    | Ok (instrument, mid, first_params, shadow) ->
      let%bind strategy_log =
        match strategy_log with
        | None -> return None
        | Some path ->
          let%map log = Strategy_log.create path ~params:first_params in
          Venue.add_observer venue (fun input ->
            Strategy_log.on_input
              log
              input
              ~now:(Time_ns.to_int_ns_since_epoch (Time_source.now time_source)));
          Some log
      in
      let close_log () =
        Option.value_map strategy_log ~default:(return ()) ~f:Strategy_log.close
      in
      let fail error =
        let%bind () = close_log () in
        fail error
      in
      let finish ~reloads live =
        let%bind report = Live.stop live in
        let tick_to_order = Live.tick_to_order live in
        let%bind () = Venue.shutdown venue in
        let%map () = close_log () in
        Ok
          { Outcome.report
          ; tick_to_order
          ; reloads
          ; shadow = Option.map shadow ~f:(fun s -> Shadow.stats s.shadow)
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
                reload_shadow ~live:next ~live_changed:true;
                Option.iter strategy_log ~f:(fun log ->
                  match Strategy_log.update_params log next with
                  | Ok () -> ()
                  | Error error ->
                    Log.Global.error_s
                      [%message "strategy log: params update failed" (error : Error.t)]);
                loop live ~current:next ~reloads:(reloads + 1)))
      in
      (match%bind start first_params with
       | Error error -> fail error
       | Ok live -> loop live ~current:first_params ~reloads:0)
  ;;
end
