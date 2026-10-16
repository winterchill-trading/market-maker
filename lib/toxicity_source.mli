(** The toxicity gate's signal from the venue's own trades: market-data's VPIN
    ([Market_data.Toxicity]) over the public trade stream, one measurement per filled
    volume bucket, as mm-core-replay's [Toxicity_input] turns buckets into
    [Strategy.on_toxicity] calls.

    Two signals are offered ([Kind]):

    - [Percentile] (the default): the bucket's VPIN percentile against the previous
      buckets ([cdf], in [[0, 1]]), what the gate's default thresholds (widen from 0.8,
      pull at 0.95) are set for. It reacts to a change of regime, but relaxes when
      one-sided flow lasts: the history fills with high values and the percentile falls
      back.
    - [Vpin]: VPIN itself (in [[0, 1]]), once the window is full. It stays high as long as
      the flow stays one-sided; thresholds need setting for the instrument's usual level.

    The imbalance is the bucket's signed order imbalance in both cases. *)

open! Core
open! Async

module Signal : sig
  type t =
    { signal : float
    ; imbalance : float (** signed flow, [(buy - sell) / volume] *)
    }
  [@@deriving sexp, compare, equal]
end

module Kind : sig
  type t =
    | Percentile
    | Vpin
  [@@deriving sexp, compare, equal, enumerate]

  (** ["percentile"], ["vpin"]. *)
  val to_string : t -> string

  val arg_type : t Command.Arg_type.t
end

module Config : sig
  type t =
    { toxicity : Market_data.Toxicity.Config.t
    ; kind : Kind.t
    }
  [@@deriving sexp_of]

  (** [Market_data.Toxicity.Config.default] with [bucket_volume], and [window] when given.
      Errors if the result does not validate. *)
  val create
    :  ?window:int
    -> ?kind:Kind.t
    -> bucket_volume:Market_data.Size.t
    -> unit
    -> t Or_error.t
end

(** The signal of one bucket; [None] for a [Percentile] without a percentile yet (the
    first bucket) and a [Vpin] whose window is not full. *)
val signal : Config.t -> Market_data.Toxicity.Event.t -> Signal.t option

(** The signals of the buckets filled by [trades] (every instrument in it). Closing the
    result stops reading [trades]. *)
val of_trades : Config.t -> Market_data.Trade.t Pipe.Reader.t -> Signal.t Pipe.Reader.t

(** [of_trades] over the feed's trades. Its other pipes are closed at once; closing the
    result closes the feed. *)
val of_feed : Config.t -> Market_data.Feed.t -> Signal.t Pipe.Reader.t
