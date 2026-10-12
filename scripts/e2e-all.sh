#!/usr/bin/env bash
# Runs scripts/e2e.sh on every venue in turn: hyperliquid, binance, bybit.
#
#   scripts/e2e-all.sh [SECONDS] [market-maker flags...]
#
# Ends with each venue's tick-to-order latency (book update to plan sent). Logs go to
# LOG_DIR/<venue> (LOG_DIR defaults to a temporary directory).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_root="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/market-maker-e2e-all.XXXXXX")}"
venues=(hyperliquid binance bybit)
failed=()
for venue in "${venues[@]}"; do
  echo "=== $venue ===" >&2
  LOG_DIR="$log_root/$venue" "$here/e2e.sh" "$venue" "$@" || failed+=("$venue")
done
echo "--- tick-to-order latency ---"
for venue in "${venues[@]}"; do
  stats="$(sed -n 's/^tick-to-order *//p' "$log_root/$venue/report.txt" 2>/dev/null || true)"
  printf '%-12s %s\n' "$venue" "${stats:-missing}"
done
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "e2e-all: failed: ${failed[*]}" >&2
  exit 1
fi
