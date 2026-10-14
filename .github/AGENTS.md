# .github: market-maker CI

- `workflows/ci.yml`: shellcheck, the ox-setup action with the pins, `libsecp256k1-dev`, build, tests.
- `workflows/nightly.yml`: builds against upstream main and runs `scripts/e2e.sh` weekly; the latency
  table goes to the job summary and the logs are uploaded as artifacts.

Rules:

- Keep the two pin lists in step; the nightly list is in the workflow's `PINS` variable.
- Do not add a job that places orders on mainnet.
- To check a run: `gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.
