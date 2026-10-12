#!/usr/bin/env bash
# Runs scripts/e2e.sh on every venue in turn: hyperliquid, binance, bybit.
#
#   scripts/e2e-all.sh [SECONDS] [market-maker flags...]
#
# Then a fault phase: one more run on FAULT_VENUE (default binance) whose simulator is
# restarted a third of the way in (see FAULT_AT in e2e.sh); it fails unless the maker
# reconnects and keeps quoting. FAULT_VENUE=none skips it. A freshly started simulator's
# book jumps for its first seconds, and the requotes it causes trip the default limit of
# 100 actions per second (a sticky halt), so this run raises it with
# -max-actions-per-sec 1000.
#
# Starts by printing the commit each sibling checkout in the workspace is at (WORKSPACE,
# default the parent of this checkout), marked "+dirty" with uncommitted changes.
#
# Ends with each venue's tick-to-order latency (book update to plan sent). Logs go to
# LOG_DIR/<venue> and LOG_DIR/fault-<venue> (LOG_DIR defaults to a temporary directory).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_root="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/market-maker-e2e-all.XXXXXX")}"
venues=(hyperliquid binance bybit)
failed=()

workspace="${WORKSPACE:-$(cd "$here/../.." && pwd)}"
echo "--- workspace $workspace ---"
for repo in market-maker fixed-decimal exchange-core parquet market-data hl-protocol \
  order-book venue-net hl-client hl-sim mm-core hl-mm binance-protocol binance-sim \
  binance-client bybit-protocol bybit-sim bybit-client; do
  dir="$workspace/$repo"
  if [[ ! -d "$dir" ]]; then
    head="missing"
  elif head="$(git -C "$dir" log -1 --format='%h %cs %s' 2>/dev/null)"; then
    [[ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ]] || head="$head +dirty"
  else
    head="not a git checkout"
  fi
  printf '%-17s %s\n' "$repo" "$head"
done

for venue in "${venues[@]}"; do
  echo "=== $venue ===" >&2
  LOG_DIR="$log_root/$venue" "$here/e2e.sh" "$venue" "$@" || failed+=("$venue")
done

fault_venue="${FAULT_VENUE:-binance}"
if [[ "$fault_venue" != none ]]; then
  seconds=60
  if [[ $# -ge 1 && "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    seconds="${1%%.*}"
  fi
  fault_at=$((seconds / 3 > 5 ? seconds / 3 : 5))
  echo "=== fault: $fault_venue, simulator restarted after ${fault_at}s ===" >&2
  FAULT_AT="$fault_at" LOG_DIR="$log_root/fault-$fault_venue" \
    "$here/e2e.sh" "$fault_venue" "$@" -max-actions-per-sec 1000 \
    || failed+=("fault-$fault_venue")
  venues+=("fault-$fault_venue")
fi

echo "--- tick-to-order latency ---"
for venue in "${venues[@]}"; do
  stats="$(sed -n 's/^tick-to-order *//p' "$log_root/$venue/report.txt" 2>/dev/null || true)"
  printf '%-14s %s\n' "$venue" "${stats:-missing}"
done
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "e2e-all: failed: ${failed[*]}" >&2
  exit 1
fi
