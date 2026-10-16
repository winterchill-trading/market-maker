# Changes

## Unreleased

- Reference guard and toxicity gate (mm-core's `Reference_guard` and `Toxicity_gate`):
  `reference_guard` and `toxicity_gate` in params files, reloaded on SIGHUP; a file may
  list only some fields of either, the rest from the base or the defaults.
- `-reference anchor | VENUE:SYMBOL[@URL]`: reference mids from the simulator's anchor
  status or another venue's public best bid and offer (`Reference_source`).
- `-toxicity-bucket`, `-toxicity-window`, `-toxicity-signal`: VPIN over the venue's own
  public trades as the gate's signal (`Toxicity_source`, over market-data's `Toxicity`).
- `Session.Make (V).connect_and_run` and the venue runners take `?reference` and
  `?toxicity`; `Session.Outcome.t` gains `plausibility` (events by kind). A record literal
  of the outcome needs the field; callers of the runners' `connect_and_run` that pass every
  optional argument explicitly need the two new ones.
- `Strategy_input.t` gains `Reference` and `Toxicity`; exhaustive matches need the cases.
  Strategy logs of older runs still read.
- `Order_event.t` gains `Plausibility` and `Toxicity`; the order log writes `guard`, `gate`
  and `toxicity` rows, and `Order_log_status` (the status viewer) shows the latest of each.
- `scripts/e2e-plausibility.sh`: frozen reference and toxic burst on an anchored hl-sim.
- Depends on `market-data`, `mm-core-replay`, `cohttp`, `cohttp-async` (no longer test
  only) and `yojson`.
