#!/usr/bin/env bash
# End-to-end run on one venue: starts that venue's simulator (seeded) on a free port,
# runs market-maker against it for SECONDS (default 60), prints the final report and
# stops the simulator.
#
#   scripts/e2e.sh hyperliquid|binance|bybit [SECONDS] [market-maker flags...]
#
# Assumed layout: market-maker is checked out next to its sibling repositories inside one
# dune workspace, so dune builds the simulators and libraries from source without pins:
#
#   <root>/dune-workspace      (lang dune 3.17)
#   <root>/market-maker  <root>/hl-sim  <root>/binance-sim  <root>/bybit-sim  ...
#
# Environment overrides: WORKSPACE (<root>, the parent of this checkout; any dune
# workspace holding market-maker and the siblings, e.g. one of symlinks), OPAM_SWITCH
# (5.2.0+ox), DUNE_BUILD_DIR (<root>/_build-market-maker), SEED (42), PORT (a free port),
# LOG_DIR (a temporary directory). The final report is also written to
# LOG_DIR/report.txt.
set -euo pipefail

usage() {
  echo "usage: $0 hyperliquid|binance|bybit [SECONDS] [market-maker flags...]" >&2
  exit 2
}
[[ $# -ge 1 ]] || usage
venue="$1"
shift
case "$venue" in
  hyperliquid | hl) venue=hyperliquid sim=hl-sim ;;
  binance) sim=binance-sim ;;
  bybit) sim=bybit-sim ;;
  *) usage ;;
esac
run_for=60
if [[ $# -ge 1 && "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  run_for="$1"
  shift
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
if [[ ! -d "$root/$sim" ]]; then
  echo "e2e: $root/$sim is missing; clone it next to market-maker" >&2
  exit 1
fi
if [[ ! -f "$root/dune-workspace" && ! -f "$root/dune-project" ]]; then
  echo "e2e: $root is not a dune workspace root; create $root/dune-workspace with" >&2
  echo "     '(lang dune 3.17)' (see the header of $0)" >&2
  exit 1
fi

switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-market-maker}"
seed="${SEED:-42}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/market-maker-e2e.XXXXXX")}"
mkdir -p "$log_dir"

echo "e2e: building $sim and market-maker (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . "$sim/bin/main.exe" market-maker/bin/main.exe)
build="$DUNE_BUILD_DIR/default"
sim_exe="$build/$sim/bin/main.exe"
mm_exe="$build/market-maker/bin/main.exe"

port="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
base_url="http://127.0.0.1:$port"
case "$venue" in
  hyperliquid) probe=(curl -sf "$base_url/info" -d '{"type":"meta"}') ;;
  binance) probe=(curl -sf "$base_url/fapi/v1/ping") ;;
  bybit) probe=(curl -sf "$base_url/v5/market/time") ;;
esac

sim_pid=""
mm_pid=""
cleanup() {
  for pid in "$mm_pid" "$sim_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "e2e: starting $sim on port $port (seed $seed), log $log_dir/sim.log" >&2
"$sim_exe" -port "$port" -seed "$seed" >"$log_dir/sim.log" 2>&1 &
sim_pid=$!

ready=""
for _ in $(seq 1 100); do
  if "${probe[@]}" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$sim_pid" 2>/dev/null; then
    echo "e2e: $sim exited early:" >&2
    cat "$log_dir/sim.log" >&2
    exit 1
  fi
  sleep 0.2
done
if [[ -z "$ready" ]]; then
  echo "e2e: $sim did not answer on $base_url" >&2
  exit 1
fi
# Let the noise traders build a two-sided book.
sleep 2

echo "e2e: running market-maker on $venue for ${run_for}s, log $log_dir/mm.log" >&2
"$mm_exe" -venue "$venue" -network local -base-url "$base_url" -run-for "$run_for" "$@" \
  >"$log_dir/report.txt" 2>"$log_dir/mm.log" &
mm_pid=$!
status=0
wait "$mm_pid" || status=$?
mm_pid=""
cat "$log_dir/report.txt"
if [[ $status -ne 0 ]]; then
  echo "e2e: market-maker exited with $status; last log lines:" >&2
  tail -20 "$log_dir/mm.log" >&2
fi
echo "e2e: logs in $log_dir" >&2
exit "$status"
