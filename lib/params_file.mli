(** Strategy parameter overrides read from a file: a sexp listing some fields of
    [Mm_core.Params.t] by name, e.g.

    {v
((levels 5)
 (base_half_spread_bps 4)
 (max_actions_per_sec 300))
    v}

    Fields that are left out keep their value from the base parameters (the instrument
    defaults and command-line flags), so deleting a line and reloading reverts it.

    [toxicity_gate] and [reference_guard] (off unless listed) are records; a file may list
    only some of their fields, the others keeping the base's value or, when the base has
    none, [Mm_core.Toxicity_gate.Config.default] and
    [Mm_core.Reference_guard.Config.default]:

    {v
((toxicity_gate ((widen_from 0.6) (pull_at 0.9) (max_signal_age_ms 10s)))
 (reference_guard ((band_bps 30) (grace_ms 1s))))
    v}

    Their [*_ms] durations, like the top-level ones, are spans ([500ms], [10s]) or integer
    milliseconds. *)

open! Core

(** Replaces the fields named in [overrides] (a list of [(name value)] pairs) and runs
    [Mm_core.Params.validate]. Unknown or repeated fields, a different [symbol] and values
    that fail validation are errors. *)
val apply : Mm_core.Params.t -> overrides:Sexp.t -> Mm_core.Params.t Or_error.t

(** [apply] with the sexp read from [path] (the whole file is one sexp). *)
val load : string -> base:Mm_core.Params.t -> Mm_core.Params.t Or_error.t
