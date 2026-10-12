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
opam pin add -n -y exchange-core-engine https://github.com/winterchill-trading/exchange-core.git
for repo in fixed-decimal exchange-core hl-protocol order-book venue-net hl-client hl-sim \
    mm-core hl-mm binance-protocol binance-sim binance-client bybit-protocol bybit-sim \
    bybit-client; do
  opam pin add -n -y $repo https://github.com/winterchill-trading/$repo.git
done
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains the sibling repositories, dune uses their
sources and the pins are not needed. `https://` and `wss://` need `async_ssl` built
against OpenSSL 3; see
[hl-client's notes](https://github.com/winterchill-trading/hl-client#macos-and-openssl).

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
order, prints the report and exits; the position is not flattened.

## Library

`Market_maker.Venues`: `Venue_choice.t = Hyperliquid | Binance | Bybit` and
`Network.t = Local | Testnet | Mainnet` (with `Command` arg types), and

```ocaml
module type RUNNER = sig
  val venue : Venue_choice.t
  val endpoint : string
  val min_notional : Symbol.t -> Usd.t option Or_error.t Deferred.t
  val connect_and_run
    :  symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Mm_core.Live.Report.t Or_error.t Deferred.t
end

val runner : ?base_url:Uri.t -> ?address:string -> ?getenv:(string -> string option)
  -> Venue_choice.t -> network:Network.t -> (module RUNNER) Or_error.t
```

## End-to-end runs

```sh
scripts/e2e.sh binance            # 60 s against a seeded binance-sim on a free port
scripts/e2e.sh bybit 30 -levels 5 # seconds, then market-maker flags
scripts/e2e-all.sh                # hyperliquid, binance and bybit in turn
```

`e2e.sh` builds the simulator and the binary in the shared dune workspace (see the
script's header), starts the simulator with `-seed 42` on a free port, waits for its
book, runs `market-maker` for the given seconds, prints the report and kills the
simulator (also on failure or Ctrl-C). Logs go to a temporary directory (`LOG_DIR`).
Runs are not bit-repeatable even with a fixed seed: request timing changes the matching
order.

## Example runs

60 seconds per venue with default parameters (`scripts/e2e-all.sh`):

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

## Tests

`dune test` checks venue parsing, endpoints, base URL overrides and the credential
checks. The adapters' own test suites run the strategy on each simulator.
