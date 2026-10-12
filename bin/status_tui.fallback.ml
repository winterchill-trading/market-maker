open! Core
open! Async

let available = false

let run _ _ ~refresh:_ =
  Deferred.Or_error.error_string
    "market-maker-status was built without bonsai_term: use -once, or build where \
     bonsai_term is installed"
;;
