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
#
# Fault injection: with FAULT_AT=SECONDS the simulator is killed that long into the run,
# kept down for FAULT_DOWN seconds (default 3) and restarted on the same port with the
# same seed; the run then fails unless the maker reconnected, resynchronised and placed
# orders again, and ended in the Running mode.
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
fault_at="${FAULT_AT:-}"
fault_down="${FAULT_DOWN:-3}"
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

start_sim() {
  local log="$1"
  echo "e2e: starting $sim on port $port (seed $seed), log $log" >&2
  "$sim_exe" -port "$port" -seed "$seed" >"$log" 2>&1 &
  sim_pid=$!
  local ready=""
  for _ in $(seq 1 100); do
    if "${probe[@]}" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$sim_pid" 2>/dev/null; then
      echo "e2e: $sim exited early:" >&2
      cat "$log" >&2
      exit 1
    fi
    sleep 0.2
  done
  if [[ -z "$ready" ]]; then
    echo "e2e: $sim did not answer on $base_url" >&2
    exit 1
  fi
}

start_sim "$log_dir/sim.log"
# Let the noise traders build a two-sided book.
sleep 2

echo "e2e: running market-maker on $venue for ${run_for}s, log $log_dir/mm.log" >&2
"$mm_exe" -venue "$venue" -network local -base-url "$base_url" -run-for "$run_for" "$@" \
  >"$log_dir/report.txt" 2>"$log_dir/mm.log" &
mm_pid=$!

# Fault phase: kill the simulator FAULT_AT seconds in, keep it down for FAULT_DOWN
# seconds and restart it on the same port. The checks below read the log from the kill on.
fault_line=""
if [[ -n "$fault_at" ]]; then
  sleep "$fault_at"
  echo "e2e: fault: stopping $sim for ${fault_down}s" >&2
  fault_line="$(wc -l <"$log_dir/mm.log")"
  kill "$sim_pid"
  wait "$sim_pid" 2>/dev/null || true
  sim_pid=""
  sleep "$fault_down"
  start_sim "$log_dir/sim-restarted.log"
  echo "e2e: fault: $sim is back" >&2
fi

status=0
wait "$mm_pid" || status=$?
mm_pid=""
cat "$log_dir/report.txt"
if [[ $status -ne 0 ]]; then
  echo "e2e: market-maker exited with $status; last log lines:" >&2
  tail -20 "$log_dir/mm.log" >&2
fi

# After a fault the maker must have reconnected and placed quotes again.
if [[ -n "$fault_line" && $status -eq 0 ]]; then
  reconnects="$(sed -n 's/^reconnects *//p' "$log_dir/report.txt")"
  after="$(tail -n "+$((fault_line + 1))" "$log_dir/mm.log")"
  check() {
    if [[ "$2" == ok ]]; then
      echo "e2e: fault check passed: $1" >&2
    else
      echo "e2e: fault check FAILED: $1" >&2
      status=1
    fi
  }
  check "reconnects >= 1 (got ${reconnects:-none})" \
    "$([[ "${reconnects:-0}" -ge 1 ]] && echo ok)"
  check "resynced after the restart" \
    "$(grep -q 'venue reconnected' <<<"$after" && echo ok)"
  check "placed orders after the restart" \
    "$(grep -q 'place \[[a-z]' <<<"$after" && echo ok)"
  check "still Running at the end" \
    "$(grep -q '^mode  *Running' "$log_dir/report.txt" && echo ok)"
fi
echo "e2e: logs in $log_dir" >&2
exit "$status"
