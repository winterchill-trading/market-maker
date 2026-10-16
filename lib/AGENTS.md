# lib: market-maker library

Library `market-maker` (module `Market_maker`). Main pieces, all described in the `Library` section
of `../README.md`:

- `Venues`: `Venue_choice`, `Network`, and the `RUNNER` signature each venue implements.
- `Session`: one run over `Mm_core.Live.Make`, with the report and tick-to-order stats.
- `Params_file`, `Shadow`, `Strategy_input`, `Strategy_log`, `Replay`: parameter files, the shadow
  strategy, the input and plan log, and the replay that compares every plan.
- `Reference_source`, `Toxicity_source`: reference mids (a simulator's anchor status or another
  venue's best bid and offer) and VPIN signals for mm-core's reference guard and toxicity gate.
- `Order_log`, `Cycle_monitor`, `Venue_script`: the order CSV, the slow-cycle counter, and the
  sequence used by `compare-venues.sh`.

Rules:

- New parameters default when absent from the file, so older files keep loading.
- Credentials come from the environment only (`BINANCE_API_KEY`, `BYBIT_API_SECRET`, `HL_PRIVATE_KEY`
  and similar). Never put them in a sexp file.
