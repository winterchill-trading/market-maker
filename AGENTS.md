# market-maker: agent guide

## Purpose

One `market-maker` binary that runs the `mm-core` strategy on Hyperliquid, Binance or Bybit, or on
their local simulators. Each venue adapter is wrapped in `Mm_core.Live.Make`. Testnet is the default
network; mainnet is refused unless the operator passes an explicit flag.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `market-maker` (module `Market_maker`): venue runners, sessions, parameter files, shadow strategy, strategy and order logs, replay, cycle monitor, reference and toxicity sources |
| `bin/` | The `market-maker` binary and the status viewer (`status_tui.bonsai.ml` or `status_tui.fallback.ml`, chosen by dune) |
| `queries/` | `fills_vs_trades.sql`, which joins fills to public trades in the Parquet tables |
| `scripts/` | `e2e.sh` (one venue against its simulator), `e2e-all.sh` (all three), `e2e-plausibility.sh` (guard and gate on an anchored hl-sim), `compare-venues.sh` |
| `test/` | Expect and unit tests, including the signed Hyperliquid test |
| `.github/` | `ci.yml` (build, test, shellcheck) and `nightly.yml` (builds against upstream main, weekly end-to-end run) |

## Build, test, docs

Run from this repository, inside the workspace:

    opam exec --switch 5.2.0+ox -- dune build --root .. @market-maker/all
    opam exec --switch 5.2.0+ox -- dune build --root .. @market-maker/runtest

Building needs `libsecp256k1-dev` (`apt-get install` on Linux, Homebrew on macOS). Several agents
building at once need `DUNE_BUILD_DIR=_build-market-maker`.

End to end: `scripts/e2e.sh <venue> [seconds] [flags]` starts a seeded simulator on a free port and
runs the binary against it. Read the script header before running it; it starts processes.

Standalone, outside the workspace: add the organization's opam repository
(`opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git`), install
the published dependencies, then run `dune build` here.

## Conventions

- Format this repository only: `dune build --root .. @market-maker/fmt --auto-promote`. Never
  `dune fmt` at the workspace root.
- Every module has an `.mli`; every public value has an odoc comment.
- Strategy changes go in `mm-core`, not here. This repository adapts venues and runs sessions.
- Signed requests: with `HL_PRIVATE_KEY` set, Hyperliquid requests are signed through the
  `hl-client` trading handle. A signed run against mainnet needs `-i-understand-mainnet`.
- Parameters reload on SIGHUP through `-params FILE`. Invalid parameters are logged and the old ones
  stay. `reference_guard` and `toxicity_gate` are records merged field by field with the defaults.
- The guard and the gate are fed by `-reference` and `-toxicity-bucket`; the sources live here
  (`Reference_source`, `Toxicity_source`), the checks in `mm-core`. Feed both to the loop and to
  the mirrors (`Strategy_input.Reference`, `Toxicity`), as `Session` does.
- Comments for humans at pinned numbers and tolerances; the latency table is measured on one machine.

## Dependencies

- Depends on sibling repositories: `exchange-core`, `mm-core`, `mm-core-replay` (same repository as
  `mm-core`), `market-data`, `hl-protocol`, `hl-client`, `hl-mm`,
  `binance-protocol`, `binance-client`, `bybit-protocol`, `bybit-client`. Tests also use `hl-sim`.
- Used by `infra` (service image and compose stack).
- CI pin order is the `pins:` list in `.github/workflows/ci.yml`; `nightly.yml` keeps its own list in
  `PINS`. Keep both in step with the dependency order.

## CI

`ci.yml` runs shellcheck on `scripts/`, then the ox-setup action with the pins, installs
`libsecp256k1-dev`, then `dune build` and `dune test`. `nightly.yml` builds against upstream main and
runs the end-to-end script weekly. The `obj-magic` job calls the reusable workflow in
`winterchill-trading/infra`. To check a run, use `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- The status viewer needs `bonsai_term`; where it is absent the fallback module is used and only
  `-once` output works.
- Runs are not bit-repeatable with a fixed seed: request timing changes the order of matching.
- The action-rate kill switch trips on the requote burst after a simulator restart. The default cap
  of 100 and the grace period (`-action-rate-grace-ms`) cover it; read the README before changing them.
- The position is not flattened on stop; `stop` only cancels resting orders.
- The plausibility e2e thresholds (VPIN widen 0.65, pull 0.85) are tuned to hl-sim's mixed flow; a
  weaker burst fails the run. `NO_BUILD=1` reuses built binaries when a sibling does not build.
- `-toxicity-signal percentile` relaxes under lasting one-sided flow (its history fills with high
  values); use `vpin` for a sustained regime.
- Hyperliquid signing is verified against SDK vectors, not against acceptance on testnet: `hl-sim`
  does not check signatures.

## Where to read more

- `README.md` (build, usage, signing, parameter files, shadow, strategy and order logs, end-to-end
  runs, venue semantics, nightly)
- `../specs/repos/market-maker.md` (module map, end-to-end, known gaps)
- `../specs/repos/mm-core.md` and `../specs/design/market-making.md`
- `../oxcaml-claude-skills/AGENTS.md` and `../oxcaml-claude-skills/GOTCHAS.md`

## Never do

- Run a signed order against mainnet, or pass `-i-understand-mainnet`, unless the task asks for it.
- Put a private key, API secret or account address in a file, a flag or a log.
- Run `opam install`, `upgrade` or `pin` that would change `ocaml-variants`, `core`, `base`,
  `async` or `ppx_jane` on the shared `5.2.0+ox` switch.
- Publish, tag or release.
- Poll CI in a loop.
