# test: market-maker tests

Expect and unit tests for the venue runners, the parameter file loader, the shadow and replay
paths, and the order log.

- The signed Hyperliquid test uses `hl-sim` as a test dependency and a throwaway key. It shows the
  signer, not venue acceptance.
- Do not add a test that needs a live venue or a funded account.
- Promote expect output with `dune promote` only after reading the diff.
