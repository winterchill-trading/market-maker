open! Core
open! Async
open Exchange_core

module Plan = struct
  type t =
    { cancels : Order_id.t list
    ; keeps : Order_id.t list
    ; places : Order_request.t list
    }
  [@@deriving sexp_of, compare, equal]

  let of_actions actions =
    let sort = List.sort ~compare:Order_id.compare in
    { cancels =
        sort
          (List.filter_map actions ~f:(function
            | Mm_core.Action.Cancel oid -> Some oid
            | Keep _ | Place _ -> None))
    ; keeps =
        sort
          (List.filter_map actions ~f:(function
            | Mm_core.Action.Keep oid -> Some oid
            | Cancel _ | Place _ -> None))
    ; places =
        List.filter_map actions ~f:(function
          | Mm_core.Action.Place order -> Some { order with client_order_id = None }
          | Keep _ | Cancel _ -> None)
    }
  ;;

  let describe (o : Order_request.t) =
    sprintf
      "%s %s@%s%s"
      (match o.side with
       | Buy -> "buy"
       | Sell -> "sell")
      (Size.to_string o.size)
      (Option.value_map o.px ~default:"market" ~f:Price.to_string)
      (if o.reduce_only then " (reduce-only)" else "")
  ;;

  let to_string_hum t =
    sprintf
      "cancel %d, keep %d, place [%s]"
      (List.length t.cancels)
      (List.length t.keeps)
      (String.concat ~sep:" " (List.map t.places ~f:describe))
  ;;
end

module Stats = struct
  type t =
    { plans : int
    ; differing : int
    ; live_mode : Mm_core.Strategy.Mode.t
    ; shadow_mode : Mm_core.Strategy.Mode.t
    }
  [@@deriving sexp_of]
end

type t =
  { mutable live : Mm_core.Strategy.t
  ; mutable shadow : Mm_core.Strategy.t
  ; mutable plans : int
  ; mutable differing : int
  }

let create ~live ~shadow =
  { live = Mm_core.Strategy.create live
  ; shadow = Mm_core.Strategy.create shadow
  ; plans = 0
  ; differing = 0
  }
;;

let update_params t ~live ~shadow =
  let open Or_error.Let_syntax in
  let%bind next_live = Mm_core.Strategy.update_params t.live live in
  let%map next_shadow = Mm_core.Strategy.update_params t.shadow shadow in
  t.live <- next_live;
  t.shadow <- next_shadow
;;

let log_difference ~live ~shadow =
  Log.Global.info
    "shadow plan differs: live %s | shadow %s"
    (Plan.to_string_hum live)
    (Plan.to_string_hum shadow)
;;

let on_input ?(on_difference = log_difference) t input ~now =
  let step strategy = Mm_core.Strategy.tick (Strategy_input.apply strategy input) ~now in
  let live, live_plan = step t.live in
  let shadow, shadow_plan = step t.shadow in
  t.live <- live;
  t.shadow <- shadow;
  if not (List.is_empty live_plan && List.is_empty shadow_plan)
  then (
    t.plans <- t.plans + 1;
    let live = Plan.of_actions live_plan in
    let shadow = Plan.of_actions shadow_plan in
    if not (Plan.equal live shadow)
    then (
      t.differing <- t.differing + 1;
      on_difference ~live ~shadow))
;;

let on_resync t ~now =
  t.live <- Mm_core.Strategy.on_resync t.live ~now;
  t.shadow <- Mm_core.Strategy.on_resync t.shadow ~now
;;

let live_mode t = Mm_core.Strategy.mode t.live
let shadow_mode t = Mm_core.Strategy.mode t.shadow

let stats t =
  { Stats.plans = t.plans
  ; differing = t.differing
  ; live_mode = live_mode t
  ; shadow_mode = shadow_mode t
  }
;;
