open! Core
open! Async

module Signal = struct
  type t =
    { signal : float
    ; imbalance : float
    }
  [@@deriving sexp, compare, equal]
end

module Kind = struct
  type t =
    | Percentile
    | Vpin
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Percentile -> "percentile"
    | Vpin -> "vpin"
  ;;

  let arg_type = Command.Arg_type.of_alist_exn (List.map all ~f:(fun t -> to_string t, t))
end

module Config = struct
  type t =
    { toxicity : Market_data.Toxicity.Config.t
    ; kind : Kind.t
    }
  [@@deriving sexp_of]

  let create ?window ?(kind = Kind.Percentile) ~bucket_volume () =
    let default = Market_data.Toxicity.Config.default ~bucket_volume in
    let%map.Or_error toxicity =
      Market_data.Toxicity.Config.validate
        { default with window = Option.value window ~default:default.window }
    in
    { toxicity; kind }
  ;;
end

let signal (config : Config.t) (e : Market_data.Toxicity.Event.t) =
  match config.kind with
  | Percentile ->
    Option.map (Mm_core_replay.Toxicity_input.signal e) ~f:(fun (signal, imbalance) ->
      { Signal.signal; imbalance })
  | Vpin ->
    Option.some_if
      (e.buckets >= config.toxicity.window)
      { Signal.signal = e.vpin; imbalance = e.imbalance }
;;

let of_trades (config : Config.t) trades =
  Market_data.Toxicity_feed.of_trades ~config:(fun _ -> Some config.toxicity) trades
  |> Pipe.filter_map ~f:(fun (e : Market_data.Toxicity.Event.t) ->
    Log.Global.debug_s [%message "toxicity" ~_:(e : Market_data.Toxicity.Event.t)];
    signal config e)
;;

let of_feed config (feed : Market_data.Feed.t) =
  let module F = (val feed) in
  Pipe.close_read F.bbo;
  Pipe.close_read F.l2;
  Pipe.close_read F.funding;
  let signals = of_trades config F.trades in
  don't_wait_for
    (let%bind () = Pipe.closed signals in
     F.close ());
  signals
;;
