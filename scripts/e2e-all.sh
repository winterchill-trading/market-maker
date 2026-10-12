#!/usr/bin/env bash
# Runs scripts/e2e.sh on every venue in turn: hyperliquid, binance, bybit.
#
#   scripts/e2e-all.sh [SECONDS] [market-maker flags...]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()
for venue in hyperliquid binance bybit; do
  echo "=== $venue ===" >&2
  "$here/e2e.sh" "$venue" "$@" || failed+=("$venue")
done
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "e2e-all: failed: ${failed[*]}" >&2
  exit 1
fi
