#!/usr/bin/env bash
# Runs one scripted order sequence (bin/venue_script.ml) against hl-sim and binance-sim,
# each started without noise traders on a free port, and diffs the venue-neutral outputs:
# order statuses, fills (price, size, maker or taker, fee rate) and final positions.
# Differences are expected; they are the semantics differences between the two venues
# (see the README). The script fails only when a run fails.
#
#   scripts/compare-venues.sh
#
# Same workspace layout and environment overrides as scripts/e2e.sh: WORKSPACE,
# OPAM_SWITCH, DUNE_BUILD_DIR, LOG_DIR (outputs are kept there as <venue>.txt).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-market-maker}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/market-maker-compare.XXXXXX")}"
mkdir -p "$log_dir"

echo "compare: building the simulators and venue_script (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  hl-sim/bin/main.exe binance-sim/bin/main.exe market-maker/bin/venue_script.exe)
build="$DUNE_BUILD_DIR/default"

sim_pid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  if [[ -n "$sim_pid" ]] && kill -0 "$sim_pid" 2>/dev/null; then
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

run_venue() {
  local venue="$1" sim="$2" probe_path="$3" port base_url
  port="$(free_port)"
  base_url="http://127.0.0.1:$port"
  echo "compare: $sim on port $port, log $log_dir/$sim.log" >&2
  "$build/$sim/bin/main.exe" -port "$port" -noise-traders 0 >"$log_dir/$sim.log" 2>&1 &
  sim_pid=$!
  for _ in $(seq 1 100); do
    if [[ "$probe_path" == /info ]]; then
      curl -sf "$base_url/info" -d '{"type":"meta"}' >/dev/null 2>&1 && break
    else
      curl -sf "$base_url$probe_path" >/dev/null 2>&1 && break
    fi
    sleep 0.2
  done
  "$build/market-maker/bin/venue_script.exe" -venue "$venue" -base-url "$base_url" \
    >"$log_dir/$venue.txt"
  kill "$sim_pid"
  wait "$sim_pid" 2>/dev/null || true
  sim_pid=""
}

run_venue hyperliquid hl-sim /info
run_venue binance binance-sim /fapi/v1/ping
echo "--- hyperliquid vs binance ---"
diff -u --label hyperliquid --label binance "$log_dir/hyperliquid.txt" "$log_dir/binance.txt" \
  || true
echo "compare: outputs in $log_dir" >&2
