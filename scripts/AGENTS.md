# scripts: market-maker end-to-end runs

- `e2e.sh <venue> [seconds] [flags]`: starts a seeded simulator on a free port, runs the binary and
  prints the report. `FAULT_AT=SECONDS` restarts the simulator mid-run. `SIGNED=1` (Hyperliquid)
  signs with a throwaway key and checks every order in the simulator's journal is signed.
- `e2e-all.sh`: prints every sibling checkout's commit, runs all three venues, then a fault run on
  Binance, and ends with a tick-to-order table.
- `compare-venues.sh`: runs the same order sequence against two simulators and diffs the output.

Rules:

- All scripts pass `shellcheck`, which CI runs.
- Scripts start processes on local ports. Check the port is free first, and kill the processes they
  start, not every process with a matching name.
- The latency table in the README is from one machine; quote the machine with any new figure.
