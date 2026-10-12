# market-maker

Multi-venue market maker: the [mm-core](https://github.com/winterchill-trading/mm-core)
strategy on Hyperliquid, Binance or Bybit, or on their local simulators.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Core, Async).
One binary wraps each venue adapter in `Mm_core.Live.Make`:

| Venue | Adapter | Simulator (default port) | Default symbol |
| --- | --- | --- | --- |
| `hyperliquid` | `Hl_mm.Hl_venue` ([hl-mm](https://github.com/winterchill-trading/hl-mm)) | [hl-sim](https://github.com/winterchill-trading/hl-sim) (3000) | `BTC` |
| `binance` | `Binance_client.Venue` ([binance-client](https://github.com/winterchill-trading/binance-client)) | [binance-sim](https://github.com/winterchill-trading/binance-sim) (3300) | `BTCUSDT` |
| `bybit` | `Bybit_client.Venue` ([bybit-client](https://github.com/winterchill-trading/bybit-client)) | [bybit-sim](https://github.com/winterchill-trading/bybit-sim) (3400) | `BTCUSDT` |

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
for repo in fixed-decimal exchange-core mm-core hl-protocol parquet market-data venue-net \
    hl-client hl-mm binance-protocol binance-client bybit-protocol bybit-client; do
  opam pin add -n -y $repo https://github.com/winterchill-trading/$repo.git
done
opam install . --deps-only --with-test
dune build && dune test
```

These are the pins CI uses (`infra/scripts/check-pins.sh` lists them). The simulators
are not needed to build; the scripts below build them from a workspace. Inside a dune
workspace that also contains the sibling repositories, dune uses their sources and the
pins are not needed. `https://` and `wss://` need `async_ssl` built
against OpenSSL 3; see
[hl-client's notes](https://github.com/winterchill-trading/hl-client#macos-and-openssl).

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## Usage

```sh
dune exec binance-sim -- -port 3300 -seed 42          # in another terminal
dune exec market-maker -- -venue binance -run-for 60

market-maker -venue hyperliquid -base-url http://127.0.0.1:3000 -levels 5
BYBIT_API_KEY=... BYBIT_API_SECRET=... market-maker -venue bybit -network testnet
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `-venue` | required | `hyperliquid`, `binance` or `bybit` |
| `-network` | `local` | `local` (the simulator on its default port), `testnet` or `mainnet` |
| `-base-url` | the network's | REST root; websocket URLs are derived from it |
| `-address` | `HL_ADDRESS`, else a simulator account | Hyperliquid account |
| `-symbol` | `BTC` / `BTCUSDT` | instrument to quote |
| `-levels` | 3 | quote levels per side |
| `-size` | about 100 USD, at least 1.2x the venue minimum | order size per level |
| `-half-spread-bps` | 3 | distance of the first level from the reservation price |
| `-skew-bps` | 4 | reservation price shift at full inventory |
| `-max-position` | 10 x size | absolute position limit |
| `-requote-ms` | 1000 | requote and open-orders poll interval |
| `-max-actions-per-sec` | 100 | halt when plans send more cancels and places than this in a second |
| `-params` | none | parameter overrides file, reloaded on SIGHUP (below) |
| `-shadow-params` | none | overrides for a shadow strategy whose differing plans are logged (below) |
| `-strategy-log` | none | write every strategy input and plan to this file (below) |
| `-run-for` | until SIGINT/SIGTERM | stop after this many seconds |
| `-summary-secs` | 10 | interval of the position and quotes summary log |
| `-log-level` | `info` | `debug`, `info`, `warn` or `error` |

Credentials come from the environment: `BINANCE_API_KEY` and `BINANCE_API_SECRET`,
`BYBIT_API_KEY` and `BYBIT_API_SECRET` (both required off the simulator; locally the key
defaults to `market-maker`, which the simulators use as the account), and `HL_ADDRESS`.
Hyperliquid requests are unsigned (hl-sim's `X-Address` convention), so only the
simulator accepts orders on that venue.

Before connecting, the binary reads the venue's minimum order value (Binance's
`MIN_NOTIONAL` filter, Bybit's `minNotionalValue`, Hyperliquid's 10 USD) and passes it to
`Params.for_instrument ~min_notional`, so the default size clears it by 20% (Binance's
BTCUSDT minimum is 100 USD: orders are 0.002 BTC there). On stop it cancels every resting
order, prints the report and exits; the position is not flattened. The report ends with
the tick-to-order latency: from a book update to the plan it led to being sent
(`mm-core`'s histogram, two significant digits).

### Parameter files and SIGHUP

`-params FILE` holds overrides of any `Mm_core.Params.t` field by name, applied over the
instrument defaults and the flags:

```
((levels 5)
 (base_half_spread_bps 4)
 (soft_max_position (0.005))
 (max_actions_per_sec 300))
```

`kill -HUP <pid>` reads the file again. Unknown or repeated fields, a different `symbol`
and values that fail `Params.validate` are logged and the current parameters stay. Valid
new parameters restart the live loop on the same connection: the old loop cancels its
orders and reports, a new strategy starts from a fresh open-orders and account snapshot,
and the final report adds up both. Quotes are off the book for one cancel-all and one
snapshot, and the strategy's generation counter (part of client order ids) starts again
at 1. A field removed from the file reverts to its default on the next reload.

### Shadow parameters

`-shadow-params FILE` (same format, also read again on SIGHUP) runs a second strategy
with those parameters on the same inputs. Its plans are never sent; each tick where they
differ from the live parameters' plan is logged:

```
shadow plan differs: live cancel 0, keep 0, place [buy 0.002@99986 buy 0.002@99966 ...] | shadow cancel 0, keep 0, place [buy 0.002@99966 buy 0.002@99946 ...]
```

and the report adds `shadow plans 23 of 23 differ`. Both sides are computed by mirrors
fed the same inputs and ticked after each one, so differences come from the parameters
alone; both see the live orders in their open-orders snapshots.

### Strategy log

`-strategy-log FILE` writes one sexp per line: a `Params` line at the start and at each
reload, then every input (`(Input (Book ...))`, `Fill`, `Open_orders`, `Account`) and the
tick after it with its plan (`(Tick (now <ns>) (plan (...)))`).
`Market_maker.Strategy_log.load` and `Replay.run` feed it through a fresh
`Mm_core.Strategy` and compare every plan: a 8 s Hyperliquid run logged 187 ticks and
17 plans (the live loop sent 19) and replayed with no mismatch. The ticks are a mirror's,
one per input; the live loop coalesces ticks on its sequencer, so its plans can come at
slightly different moments. Books make the file grow by about 20 KB a second.

## Library

`Market_maker.Venues`: `Venue_choice.t = Hyperliquid | Binance | Bybit` and
`Network.t = Local | Testnet | Mainnet` (with `Command` arg types), and

```ocaml
module type RUNNER = sig
  val venue : Venue_choice.t
  val endpoint : string
  val min_notional : Symbol.t -> Usd.t option Or_error.t Deferred.t
  val connect_and_run
    :  ?reload:unit Pipe.Reader.t
    -> ?shadow_params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> ?strategy_log:string
    -> symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Session.Outcome.t Or_error.t Deferred.t
end

val runner : ?base_url:Uri.t -> ?address:string -> ?getenv:(string -> string option)
  -> Venue_choice.t -> network:Network.t -> (module RUNNER) Or_error.t
```

The other modules:

- `Session.Make (V)`: one run on a venue (`connect_and_run` above) over
  `Mm_core.Live.Make`; `Session.Outcome.t` is the live report, the tick-to-order stats,
  the number of reloads and the shadow counts.
- `Restartable_venue.Make (V)`: a `Venue.S` whose `close` does nothing, so a live loop can
  stop and a new one start on the same connection (`next_loop`, `shutdown`); observers
  see every value the strategy is fed.
- `Params_file`: `apply` and `load` for the override files.
- `Shadow`: the shadow strategy and its plan comparison.
- `Strategy_input`, `Strategy_log`: the logged events, writer, loader and replay.

## End-to-end runs

```sh
scripts/e2e.sh binance            # 60 s against a seeded binance-sim on a free port
scripts/e2e.sh bybit 30 -levels 5 # seconds, then market-maker flags
FAULT_AT=10 scripts/e2e.sh hl 30  # restart hl-sim 10 s in, check the recovery
scripts/e2e-all.sh                # all three, then a fault run on binance
scripts/compare-venues.sh         # one order sequence on hl-sim and binance-sim, diffed
```

`e2e.sh` builds the simulator and the binary in the dune workspace (the parent of this
checkout, or `WORKSPACE`; see the script's header), starts the simulator with `-seed 42`
on a free port, waits for its book, runs `market-maker` for the given seconds, prints the
report and kills the simulator (also on failure or Ctrl-C). Logs and `report.txt` go to
a temporary directory (`LOG_DIR`). Runs are not bit-repeatable even with a fixed seed:
request timing changes the matching order.

With `FAULT_AT=SECONDS`, `e2e.sh` kills the simulator that far into the run, keeps it
down for `FAULT_DOWN` seconds (3) and restarts it on the same port. The run then fails
unless the report counts a reconnect, the log shows a resync and a plan placing orders
after the kill, and the final mode is `Running`.

`e2e-all.sh` first prints the commit of every sibling checkout (`+dirty` with local
changes), runs the three venues, then the fault run on `FAULT_VENUE` (default `binance`,
`none` skips it) with the restart a third of the way in, and ends with a tick-to-order
table. The fault run passes `-max-actions-per-sec 1000`: a freshly started simulator's
book jumps for its first seconds, the maker requotes on every jump, and the default cap
of 100 actions per second trips a halt, which is permanent (seen on all three venues).

## Example runs

30 seconds per venue with default parameters (`scripts/e2e-all.sh 30`, on an M-series
Mac):

```
--- tick-to-order latency ---
hyperliquid    n=59 p50=52us p99=118us max=118us
binance        n=70 p50=59us p99=763us max=763us
bybit          n=75 p50=43us p99=1.8ms max=1.8ms
fault-binance  n=54 p50=62us p99=996us max=996us
```

The fault run reconnected twice (public and private streams), resynchronised and kept
quoting; the restarted simulator had lost the resting orders and the account, which the
next snapshot picked up.

Earlier 60 second runs, before the tick-to-order line was added:

```
--- market-maker report (hyperliquid) ---
elapsed          60.3s
fills            68 (68 maker)
volume           6537.4784 USD
realized pnl     -0.3995 USD
unrealized pnl   -0.0015 USD
fees             0.6537 USD
total pnl        -1.0548 USD
final position   -0.00019
last mid         99843.5
account value    999998.9493 USD
plans            158
orders           444 placed, 0 rejected, 380 cancelled
reconnects       0
mode             Running
```

```
--- market-maker report (binance) ---
elapsed          60.3s
fills            74 (74 maker)
volume           14823.0686 USD
realized pnl     1.1298 USD
unrealized pnl   -0.4876 USD
fees             2.9646 USD
total pnl        -2.3224 USD
final position   0.008
last mid         99903.15
account value    999997.5372 USD
plans            143
orders           377 placed, 3 rejected, 303 cancelled
  rejected    3 x post-only order would cross, bbo none@none
reconnects       0
mode             Running
```

```
--- market-maker report (bybit) ---
elapsed          60.3s
fills            65 (65 maker)
volume           6483.6891 USD
realized pnl     -0.3238 USD
unrealized pnl   -0.2192 USD
fees             1.2967 USD
total pnl        -1.8397 USD
final position   0.001
last mid         99244.95
account value    999998.1552 USD
plans            182
orders           490 placed, 4 rejected, 425 cancelled
  rejected    4 x post-only order would cross, bbo none@none
reconnects       0
mode             Running
```

The few rejections are post-only quotes that would have crossed after the book moved
while the request was in flight. Binance and Bybit do not return the best bid and offer
with the rejection, hence `bbo none@none`.

## Venue semantics (compare-venues.sh)

`scripts/compare-venues.sh` starts hl-sim and binance-sim without noise traders and runs
`bin/venue_script.ml` on each: a maker account rests a bid and an ask, a taker trades
against them with post-only, GTC, IOC, market and reduce-only orders, then sends orders
with an off-tick price, an odd lot and a small notional. The outputs are venue-neutral
(`exchange-core` statuses through each adapter) and diffed. What differs:

| Case | Hyperliquid (hl-sim, `Hl_mm.Hl_venue`) | Binance (binance-sim, `Binance_client.Venue`) |
| --- | --- | --- |
| Post-only order that would cross | rejected, with the best bid and ask | rejected, no bid and ask (`bbo none@none`) |
| Market order | rejected by the adapter: send an IOC limit order | filled |
| Price 99000.5 | `Invalid_price` (more than 5 significant figures) | valid tick (0.1), rejected as below the minimum value |
| Size 0.0005 | valid (lot 0.00001) | `Invalid_size` (lot 0.001) |
| 90 USD order | rests (minimum 10 USD) | `Below_min_value` (minimum 100 USD) |
| Fees | maker 1.0 bps, taker 3.5 bps | maker 2.0 bps, taker 5.0 bps |

The same on both: a crossing GTC fills at the resting price as taker; an IOC fills what
it can and drops the rest; a self-crossing order is rejected (`Self_trade`) and the
resting order stays; an IOC on an empty side is `No_liquidity`; a reduce-only order that
would grow the position is rejected, and one larger than the position fills only the
position; cancelling an order twice is not an error.

## Tests

`dune test` checks venue parsing, endpoints, base URL overrides and the credential
checks, and drives `Session` over an in-memory venue on a synthetic clock: tick-to-order
stats, reloads (rejected, applied, unchanged) through a pipe standing in for SIGHUP,
shadow plans, and a strategy log that replays to the same plans. `Params_file`, `Shadow`,
`Strategy_log` and `Restartable_venue` have their own tests. The adapters' own test
suites run the strategy on each simulator.
