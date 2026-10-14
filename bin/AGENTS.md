# bin: market-maker binary

`main.ml` parses flags (`-venue`, `-network`, `-symbol`, strategy flags, `-params`, `-shadow-params`,
`-strategy-log`, `-order-log`, `-run-for`, `-i-understand-mainnet`) and starts a `Session`.

`status_viewer.ml` follows an order log and shows resting orders, position, fees and latency.
dune selects `status_tui.bonsai.ml` when `bonsai_term` is installed and `status_tui.fallback.ml`
otherwise. `venue_script.ml` runs the order sequence used by `compare-venues.sh`.

Rules:

- Flag names are used by the scripts and by `infra`;
- Mainnet is refused unless `-i-understand-mainnet` is passed; do not weaken the check.
