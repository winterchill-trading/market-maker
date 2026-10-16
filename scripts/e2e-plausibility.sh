#!/usr/bin/env bash
# End-to-end run of the reference guard and the toxicity gate on hl-sim:
#
#   scripts/e2e-plausibility.sh [SECONDS]
#
# Starts two simulators on free ports: a reference hl-sim (its own noise traders), and the
# venue hl-sim whose BTC is anchored live on the reference (-anchor hyperliquid:BTC with
# -anchor-base-url, a few noise traders of its own). market-maker quotes BTC on the venue
# with -reference anchor (the venue's anchor status), a VPIN toxicity signal over the
# venue's public trades, and a params file that turns on the guard and the gate. Then:
#
# 1. Frozen reference: FREEZE_AT seconds in, the reference simulator is paused (SIGSTOP)
#    for FREEZE_FOR seconds and resumed (SIGCONT). The venue's anchor goes stale, no
#    reference reaches the maker, and the guard must pull the quotes
#    (reference_missing), then resume once the anchor is fresh again.
# 2. Toxic flow: BURST_AT seconds in, an account sends BURST_ORDERS immediate-or-cancel
#    buys of BURST_SIZE BTC, one every BURST_EVERY seconds. VPIN climbs bucket by bucket,
#    and the gate must widen the quotes before it pulls them.
#
# The checks read the order log (rows guard, gate, toxicity, place) and fail the run when
# a phase did not happen in that order. SECONDS defaults to 75.
#
# Environment overrides: WORKSPACE, OPAM_SWITCH, DUNE_BUILD_DIR and LOG_DIR as in e2e.sh;
# REF_PORT and VENUE_PORT (free ports by default); FREEZE_AT (15), FREEZE_FOR (8);
# BURST_AT (35), BURST_ORDERS (100), BURST_SIZE (0.02), BURST_EVERY (0.1); NO_BUILD=1
# runs the binaries already in DUNE_BUILD_DIR (when a sibling does not build). Only the
# two simulators and the maker started here are stopped, by pid. Nothing is signed: the
# script only talks to the local simulators.
set -euo pipefail

run_for=75
if [[ $# -ge 1 && "$1" =~ ^[0-9]+$ ]]; then
  run_for="$1"
  shift
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
if [[ ! -d "$root/hl-sim" ]]; then
  echo "e2e-plausibility: $root/hl-sim is missing; clone it next to market-maker" >&2
  exit 1
fi
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-market-maker}"
freeze_at="${FREEZE_AT:-15}"
freeze_for="${FREEZE_FOR:-8}"
burst_at="${BURST_AT:-35}"
burst_orders="${BURST_ORDERS:-100}"
burst_size="${BURST_SIZE:-0.02}"
burst_every="${BURST_EVERY:-0.1}"
unset HL_PRIVATE_KEY HL_ADDRESS
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/market-maker-plausibility.XXXXXX")}"
mkdir -p "$log_dir"

if [[ -z "${NO_BUILD:-}" ]]; then
  echo "e2e-plausibility: building hl-sim and market-maker (switch $switch)" >&2
  (cd "$root" && opam exec --switch "$switch" -- dune build --root . hl-sim/bin/main.exe market-maker/bin/main.exe)
fi
build="$DUNE_BUILD_DIR/default"
sim_exe="$build/hl-sim/bin/main.exe"
mm_exe="$build/market-maker/bin/main.exe"

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
ref_port="${REF_PORT:-$(free_port)}"
venue_port="${VENUE_PORT:-$(free_port)}"
if [[ "$ref_port" == "$venue_port" ]]; then venue_port="$(free_port)"; fi
ref_url="http://127.0.0.1:$ref_port"
venue_url="http://127.0.0.1:$venue_port"
now_ns() { python3 -c 'import time; print(time.time_ns())'; }

ref_pid=""
venue_pid=""
mm_pid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  # A paused simulator must be resumed before it can act on SIGTERM.
  if [[ -n "$ref_pid" ]]; then kill -CONT "$ref_pid" 2>/dev/null || true; fi
  for pid in "$mm_pid" "$venue_pid" "$ref_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_for() {
  local what="$1" pid="$2"
  shift 2
  for _ in $(seq 1 150); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "e2e-plausibility: $what exited early" >&2
      exit 1
    fi
    sleep 0.2
  done
  echo "e2e-plausibility: $what did not come up" >&2
  exit 1
}

echo "e2e-plausibility: reference hl-sim on $ref_port, venue hl-sim on $venue_port, logs in $log_dir" >&2
"$sim_exe" -port "$ref_port" -seed 42 >"$log_dir/ref-sim.log" 2>&1 &
ref_pid=$!
wait_for "reference hl-sim" "$ref_pid" curl -sf "$ref_url/info" -d '{"type":"meta"}'
"$sim_exe" -port "$venue_port" -seed 43 \
  -anchor hyperliquid:BTC -anchor-base-url "$ref_url" \
  -anchor-noise 4 -anchor-max-staleness-ms 2000 -anchor-status-interval-s 5 \
  >"$log_dir/venue-sim.log" 2>&1 &
venue_pid=$!
# The maker exits on an empty book: wait for the anchor to be fresh first.
wait_for "venue hl-sim anchor" "$venue_pid" \
  bash -c "curl -sf '$venue_url/status' | grep -q '\"fresh\":true'"
sleep 2

# The guard pulls after 2 s without a fresh reference (the venue's anchor itself goes
# stale 2 s after the reference falls silent). Its band is wide because the burst pushes
# the venue's thin book away from the reference for a while. The gate reads VPIN itself
# over 10 buckets of 0.05 BTC: 0.4 to 0.6 on this simulator's mixed flow (measured on
# one machine), past 0.85 within a few seconds of the burst.
params="$log_dir/params.sexp"
cat >"$params" <<'EOF'
((reference_guard
  ((band_bps 150) (grace_ms 1s) (max_reference_age_ms 2s) (stale_reference Pull)))
 (toxicity_gate
  ((widen_from 0.65) (pull_at 0.85) (max_extra_half_spread_bps 10) (max_signal_age_ms 30s))))
EOF

order_log="$log_dir/orders.csv"
start_ns="$(now_ns)"
echo "e2e-plausibility: market-maker for ${run_for}s" >&2
"$mm_exe" -venue hyperliquid -network local -base-url "$venue_url" -run-for "$run_for" \
  -params "$params" -reference anchor \
  -toxicity-bucket 0.05 -toxicity-window 10 -toxicity-signal vpin \
  -order-log "$order_log" "$@" \
  >"$log_dir/report.txt" 2>"$log_dir/mm.log" &
mm_pid=$!

sleep "$freeze_at"
freeze_ns="$(now_ns)"
echo "e2e-plausibility: freezing the reference for ${freeze_for}s" >&2
kill -STOP "$ref_pid"
sleep "$freeze_for"
kill -CONT "$ref_pid"
thaw_ns="$(now_ns)"
echo "e2e-plausibility: reference resumed" >&2

sleep "$(python3 -c "print(max(0, $burst_at - $freeze_at - $freeze_for))")"
burst_ns="$(now_ns)"
echo "e2e-plausibility: toxic burst, $burst_orders buys of $burst_size" >&2
limit="$(curl -sf "$ref_url/info" -d '{"type":"allMids"}' |
  python3 -c 'import json, sys; print(int(float(json.load(sys.stdin)["BTC"]) * 1.02))')"
filled=0
for i in $(seq 1 "$burst_orders"); do
  body="{\"action\":{\"type\":\"order\",\"grouping\":\"na\",\"orders\":[{\"a\":0,\"b\":true,\"p\":\"$limit\",\"s\":\"$burst_size\",\"r\":false,\"t\":{\"limit\":{\"tif\":\"Ioc\"}}}]},\"nonce\":$i}"
  if curl -sf "$venue_url/exchange" -H 'X-Address: 0x00000000000000000000000000000000000000bb' \
    -d "$body" | grep -q '"filled"'; then
    filled=$((filled + 1))
  fi
  sleep "$burst_every"
done
burst_end_ns="$(now_ns)"
echo "e2e-plausibility: burst done, $filled of $burst_orders filled" >&2

status=0
wait "$mm_pid" || status=$?
mm_pid=""
cat "$log_dir/report.txt"
if [[ $status -ne 0 ]]; then
  echo "e2e-plausibility: market-maker exited with $status; last log lines:" >&2
  tail -20 "$log_dir/mm.log" >&2
  exit "$status"
fi

# The checks, over the order log's local_ts (column 1), event (5) and status (11).
python3 - "$order_log" "$start_ns" "$freeze_ns" "$thaw_ns" "$burst_ns" "$burst_end_ns" <<'EOF' || status=1
import csv, sys

path, start, freeze, thaw, burst, burst_end = sys.argv[1], *map(int, sys.argv[2:])
rows = [(int(r["local_ts"]), r["event"], r["status"], r["detail"])
        for r in csv.DictReader(open(path))]
ok = True

def s(ns):
    return f"{(ns - start) / 1e9:.1f}s"

def check(what, passed):
    global ok
    print(f"e2e-plausibility: {'passed' if passed else 'FAILED'}: {what}", file=sys.stderr)
    ok = ok and passed

def first(event, status, after, before=None):
    for ts, e, st, _ in rows:
        if e == event and st == status and ts >= after and (before is None or ts < before):
            return ts
    return None

def places(after, before):
    return sum(1 for ts, e, _, _ in rows if e == "place" and after <= ts < before)

for ts, e, st, detail in rows:
    if e in ("guard", "gate"):
        print(f"  {s(ts):>7}  {e} {st}  {detail}", file=sys.stderr)

# 1. Frozen reference.
missing = first("guard", "reference_missing", freeze, burst)
check(f"guard pulled on the frozen reference (at {s(missing) if missing else '-'})",
      missing is not None)
if missing is not None:
    resumed = first("guard", "resumed", missing, burst)
    check(f"guard resumed after the thaw (at {s(resumed) if resumed else '-'})",
          resumed is not None and resumed >= thaw)
    if resumed is not None:
        check(f"no quotes placed while pulled ({places(missing, resumed)} place rows)",
              places(missing, resumed) == 0)
        check("quotes placed again after resuming",
              places(resumed, burst) > 0)

# 2. Toxic burst.
widening = first("gate", "widening", burst)
pulled = first("gate", "pulled", burst)
check(f"gate widened during the burst (at {s(widening) if widening else '-'})",
      widening is not None and widening <= burst_end)
check(f"gate pulled after widening (at {s(pulled) if pulled else '-'})",
      pulled is not None and widening is not None and pulled > widening)
widened_toxicity = [ts for ts, e, st, _ in rows
                    if e == "toxicity" and st == "widen" and ts >= burst]
check(f"toxicity rows with a widen decision ({len(widened_toxicity)})",
      len(widened_toxicity) > 0)
if widening is not None:
    check("quotes placed while widening, before the pull",
          places(widening, pulled or burst_end) > 0)
if pulled is not None:
    # Pulled until the gate's next change (widening again or cleared).
    end = next((ts for ts, e, _, _ in rows if e == "gate" and ts > pulled),
               max(ts for ts, _, _, _ in rows))
    check(f"no quotes placed while pulled ({places(pulled, end)} place rows)",
          places(pulled, end) == 0)
sys.exit(0 if ok else 1)
EOF
echo "e2e-plausibility: logs in $log_dir" >&2
exit "$status"
