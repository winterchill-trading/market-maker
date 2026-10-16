# market-maker

Multi-venue market maker: the [mm-core](https://github.com/winterchill-trading/mm-core)
strategy on Hyperliquid, Binance or Bybit, or on their local simulators.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Core, Async).
One binary wraps each venue adapter in `Mm_core.Live.Make`:

| Venue | Adapter | Simulator (default port) | Default symbol |
| --- | --- | --- | --- |
| `hyperliquid` | `Hl_mm.Hl_venue.Trading` ([hl-mm](https://github.com/winterchill-trading/hl-mm)) | [hl-sim](https://github.com/winterchill-trading/hl-sim) (3000) | `BTC` |
| `binance` | `Binance_client.Venue` ([binance-client](https://github.com/winterchill-trading/binance-client)) | [binance-sim](https://github.com/winterchill-trading/binance-sim) (3300) | `BTCUSDT` |
| `bybit` | `Bybit_client.Venue` ([bybit-client](https://github.com/winterchill-trading/bybit-client)) | [bybit-sim](https://github.com/winterchill-trading/bybit-sim) (3400) | `BTCUSDT` |

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
for repo in fixed-decimal exchange-core mm-core hl-protocol parquet market-data venue-net \
    hl-client hl-mm binance-protocol binance-client bybit-protocol bybit-client \
    order-book price-anchor hl-sim; do
  opam pin add -n -y $repo https://github.com/winterchill-trading/$repo.git
done
opam pin add -n -y exchange-core-engine https://github.com/winterchill-trading/exchange-core.git
opam install . --deps-only --with-test
dune build && dune test
```

These are the pins CI uses (`infra/scripts/check-pins.sh` lists them). hl-sim and its
engine are test dependencies (the signed Hyperliquid test runs against it); the other
simulators are not needed to build; the scripts below build them from a workspace.
Inside a dune workspace that also contains the sibling repositories, dune uses their sources and the
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
HL_PRIVATE_KEY=... market-maker -venue hyperliquid -network testnet
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `-venue` | required | `hyperliquid`, `binance` or `bybit` |
| `-network` | `local` | `local` (the simulator on its default port), `testnet` or `mainnet` |
| `-base-url` | the network's | REST root; websocket URLs are derived from it |
| `-address` | `HL_ADDRESS`, else the `HL_PRIVATE_KEY` address, else a simulator account | Hyperliquid account |
| `-i-understand-mainnet` | off | allow signed Hyperliquid orders on mainnet |
| `-symbol` | `BTC` / `BTCUSDT` | instrument to quote |
| `-levels` | 3 | quote levels per side |
| `-size` | about 100 USD, at least 1.2x the venue minimum | order size per level |
| `-half-spread-bps` | 3 | distance of the first level from the reservation price |
| `-skew-bps` | 4 | reservation price shift at full inventory |
| `-max-position` | 10 x size | absolute position limit |
| `-requote-ms` | 1000 | requote and open-orders poll interval |
| `-max-actions-per-sec` | 100 | halt when plans send more cancels and places than this in a second |
| `-action-rate-grace-ms` | 5000 | after a venue reconnect, neither count nor check the action rate for this long |
| `-action-rate-cooldown-ms` | none (the halt is permanent) | clear an action rate halt this long after it tripped |
| `-params` | none | parameter overrides file, reloaded on SIGHUP (below) |
| `-shadow-params` | none | overrides for a shadow strategy whose differing plans are logged (below) |
| `-strategy-log` | none | write every strategy input and plan to this file (below) |
| `-order-log` | none | write the order lifecycle to this CSV file (below) |
| `-reference` | none | reference mids for `reference_guard`: `anchor` or `VENUE:SYMBOL[@URL]` (below) |
| `-toxicity-bucket` | none (no signal) | VPIN bucket size in base units over the venue's public trades, for `toxicity_gate` |
| `-toxicity-window` | 50 | buckets in the VPIN mean |
| `-toxicity-signal` | `percentile` | `percentile` (VPIN against its history) or `vpin` (VPIN itself) |
| `-run-for` | until SIGINT/SIGTERM | stop after this many seconds |
| `-summary-secs` | 10 | interval of the position and quotes summary log |
| `-log-level` | `info` | `debug`, `info`, `warn` or `error` |

Credentials come from the environment: `BINANCE_API_KEY` and `BINANCE_API_SECRET`,
`BYBIT_API_KEY` and `BYBIT_API_SECRET` (both required off the simulator; locally the key
defaults to `market-maker`, which the simulators use as the account), `HL_PRIVATE_KEY`
and `HL_ADDRESS`.

### Hyperliquid signing

With `HL_PRIVATE_KEY` set (64 hex digits), Hyperliquid exchange requests are signed
through `hl-client`'s trading handle (`Hl_mm.Hl_venue.Trading`), and the account is
`-address`, else `HL_ADDRESS`, else the key's address (so an agent key can trade for
another account). Without it requests are unsigned (hl-sim's `X-Address` convention) and
only the simulator accepts orders. The startup log line names the account and whether
requests are `unsigned` or `signed for testnet`.

The signing domain is testnet unless the REST root is `api.hyperliquid.xyz`. A signed
run against mainnet (`-network mainnet` or a mainnet `-base-url`) refuses to start unless
`-i-understand-mainnet` is passed; nothing defaults to mainnet (`-network` defaults to
`local`). hl-sim does not check signatures, so a signed run against it shows that orders
go out signed, not that the exchange accepts them; the tests check the signer by
recovering it from the journalled requests.

Before connecting, the binary reads the venue's minimum order value (Binance's
`MIN_NOTIONAL` filter, Bybit's `minNotionalValue`, Hyperliquid's 10 USD) and passes it to
`Params.for_instrument ~min_notional`, so the default size clears it by 20% (Binance's
BTCUSDT minimum is 100 USD: orders are 0.002 BTC there). On stop it cancels every resting
order, prints the report and exits; the position is not flattened. The report ends with
the tick-to-order latency: from a book update to the plan it led to being sent
(`mm-core`'s histogram, two significant digits).

### Long Async cycles

Every job in the process (book handling, planning, JSON decoding, the shadow and the
logs) runs on one Async scheduler, so a long cycle delays the next requote by its whole
length. The binary watches the scheduler (`Cycle_monitor`, over `Scheduler.long_cycles`):
a cycle over 20 ms is logged as `("warning: long async cycle" (cycle 23ms) (over 20ms))`,
cycles over 20 ms and over 50 ms are counted, a `(status (async_cycles "..."))` line
repeats the counts every `-summary-secs`, and the report has them:

```
async cycles     0 over 50ms, 0 over 20ms, max -
```

A 30 s `scripts/e2e-all.sh` run (which now ends with a long cycles table) had none on any
venue, fault run included; tick-to-order p50 29 to 31 us, p99 615 us (fault-binance) to
42 ms (bybit, a book that waited for a plan in flight, not a long cycle).

### Parameter files and SIGHUP

`-params FILE` holds overrides of any `Mm_core.Params.t` field by name, applied over the
instrument defaults and the flags:

```
((levels 5)
 (base_half_spread_bps 4)
 (soft_max_position (0.005))
 (max_actions_per_sec 300)
 (requote_interval_ms 500ms))
```

Durations (the `_ms` fields) are `Time_ns.Span.t`: a value is a span (`500ms`, `2s`,
`1m`) or, as in older files, a bare integer of milliseconds, so `(requote_interval_ms
500)` and `(requote_interval_ms 500ms)` are the same. Logged parameters print spans. The
`-*-ms` flags still take integer milliseconds.

`kill -HUP <pid>` reads the file again. Unknown or repeated fields, a different `symbol`
and values that fail `Params.validate` are logged and the current parameters stay. Valid
new parameters go to the running loop (`Mm_core.Live.update_params`): no restart and no
cancel-all. The strategy keeps its market state, inventory, resting orders, generation
counter and kill-switch history; the next tick requotes and the reconciler keeps the
orders that still match the new ladder and replaces the rest. A changed
`requote_interval_ms` re-arms the poll timer; a halted strategy stays halted. If the loop
rejects the parameters (it is stopping, or they name another symbol) the error is logged
and the current ones stay. A field removed from the file reverts to its default on the next reload.

The action rate kill switch has two keys besides `max_actions_per_sec`, also settable by
flag: `action_rate_grace_ms` (default 5000) is the window after a venue reconnect in
which actions are neither counted nor checked, so the requote burst after a resync (a
restarted simulator, a dropped stream) cannot trip the switch; `action_rate_cooldown_ms`
(default none) clears a `Max_action_rate` halt that long after it tripped. Both are left
out of the parameter sexp at their defaults; in a file the cooldown is a span or a number
of milliseconds (`(action_rate_cooldown_ms 30s)` or `(action_rate_cooldown_ms 30000)`)
and leaving it out means none.

### Reference guard and toxicity gate

Two checks from mm-core, both off unless the parameters name them, both reloadable on
SIGHUP like every other field:

```
((reference_guard ((band_bps 30) (grace_ms 1s) (max_reference_age_ms 5s)))
 (toxicity_gate ((widen_from 0.65) (pull_at 0.85) (max_signal_age_ms 30s))))
```

A file may list only some fields of either record; the others keep the base parameters'
value or, when the base has none, `Reference_guard.Config.default` and
`Toxicity_gate.Config.default`, so `(toxicity_gate ())` turns the gate on with its
defaults. Their `_ms` durations are spans or integer milliseconds, as at the top level.
Deleting the line and reloading turns the check off again.

- The **reference guard** pulls the quotes while the venue mid stays outside `band_bps` of
  a reference mid for longer than `grace_ms`, or when no reference younger than
  `max_reference_age_ms` has arrived (`stale_reference Pull`, the default). The reference
  comes from `-reference`: `anchor` polls the simulator's own anchor when it runs with
  `-anchor` and passes the anchor's `reference_price` while it is fresh (a stale anchor
  passes nothing, so the guard sees the reference age); `VENUE:SYMBOL[@URL]` takes the mid
  of another venue's public best bid and offer (Hyperliquid, Binance or Bybit, its mainnet
  without `@URL`, read-only). A reference feed only sends on top-of-book changes, so keep
  `max_reference_age_ms` above the reference's quiet spells.
- The **toxicity gate** widens, skews and shrinks the quotes as a toxicity signal rises
  past `widen_from`, and pulls them at `pull_at`. `-toxicity-bucket SIZE` measures VPIN
  (market-data's `Toxicity`) over buckets of that much base volume of the venue's own
  public trades; each filled bucket is one measurement (`Toxicity_source`, the pattern of
  mm-core-replay's `Toxicity_input`). `-toxicity-signal percentile` (default) passes the
  VPIN percentile against its history, which the gate's default thresholds are set for;
  it jumps on a change of regime but relaxes when one-sided flow lasts. `vpin` passes VPIN
  itself once `-toxicity-window` buckets are full; it stays high while the flow stays
  one-sided, and its thresholds need setting from the instrument's usual level.

Either check set without its source is logged as an error at start and on every reload
that keeps it (a guard that pulls on a missing reference would never quote). Reference
mids and measurements also go to the shadow strategy and the strategy log (`Reference`
and `Toxicity` inputs, with their time), so a replay sees them.

The order log gets a `guard` row per guard event (`diverged`, `reference_jumped`,
`reference_missing`, `resumed`), a `gate` row per change of the gate's decision
(`widening`, `pulled`, `cleared`) and a `toxicity` row per measurement with the decision
it leads to (`normal`, `widen` with the extra half-spread, shift and size factor, or
`pull`); the status viewer shows the latest of each, and the report counts the events:

```
hyperliquid BTC  last row 125.1s ago
position 0.00083  volume 10540.30017 USD  fees 1.58104489 USD
place 455  ack 455  cancel 384  fill 120  update 905
ack latency median 0.73ms max 16.61ms (last 200)
guard     resumed (176.9s ago)
gate      cleared (141.6s ago)
toxicity  normal (127.6s ago)  signal=0.5783 imbalance=-1.0000
```

(`market-maker-status -once` on the order log of an `e2e-plausibility.sh` run, two
minutes after it ended); that run's report ended with

```
plausibility     gate cleared 2, gate pulled 3, gate widening 5, guard reference_missing 1, guard resumed 1
```

Where each simulator serves its anchor status, for `-reference anchor`:

| Venue | Anchor status | Anchor named by |
| --- | --- | --- |
| hyperliquid (hl-sim) | `GET /status`, the `anchors` list (`fresh` true or false) | its spec, `hyperliquid:BTC=BTC` |
| binance (binance-sim) | `GET /sim/anchor` (`state` fresh or stale) | `sim_symbol` |
| bybit (bybit-sim) | `GET /sim/anchor` (`fresh` true or false) | `symbol` |

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

`-strategy-log FILE` writes one sexp per line: a `Params` line at the start, an
`Update_params` line at each reload, then every input (`(Input (Book ...))`, `Fill`, `Open_orders`, `Account`) and the
tick after it with its plan (`(Tick (now <ns>) (plan (...)))`).
`Market_maker.Strategy_log.load` and `Replay.run` feed it through a fresh
`Mm_core.Strategy` (updated in place at each `Update_params`) and compare every plan: a 8 s Hyperliquid run logged 187 ticks and
17 plans (the live loop sent 19) and replayed with no mismatch. The ticks are a mirror's,
one per input; the live loop coalesces ticks on its sequencer, so its plans can come at
slightly different moments. Books make the file grow by about 20 KB a second.

### Order log

`-order-log FILE` writes one CSV row per order event: every place and cancel request
before it is sent (`place`, `cancel`, `cancel_all`), the venue's answer when it comes
back (`ack` with `resting`, `filled`, `rejected` or `error`; `cancel_ack`,
`cancel_all_ack`), and every order update and fill from the venue's private feed
(`update`, `fill`). `local_ts` is the maker's clock when the event was seen, `venue_ts`
the venue's timestamp of an update or fill, both nanoseconds since the epoch. The columns
are listed in `lib/order_log.mli`; a 15 s binance-sim run wrote 695 rows:

```
local_ts,venue_ts,venue,symbol,event,side,price,size,order_id,client_order_id,status,trade_id,fee,detail
1791844075720915000,,binance,BTCUSDT,place,buy,99991.6,0.002,,0x42544355534454000001000000000000,,,,
1791844077101744000,1791844077101000000,binance,BTCUSDT,fill,buy,99983.6,0.002,371,0x42544355534454000000000000000003,maker,46,0.03999344,
```

DuckDB reads it directly (`all_varchar` keeps prices exact; cast them to
`DECIMAL(18, 8)`):

```sql
CREATE VIEW orders AS SELECT * FROM read_csv('orders.csv', header = true, all_varchar = true);
-- request to answer, per order
SELECT median(a.local_ts::BIGINT - p.local_ts::BIGINT) / 1e6 AS median_ack_ms
FROM orders p JOIN orders a USING (client_order_id)
WHERE p.event = 'place' AND a.event = 'ack';
```

On that run: 116 acks, median 0.62 ms, p99 13.6 ms; the private feed delivered fills
0.92 ms (median) after their venue timestamp.

[`queries/fills_vs_trades.sql`](queries/fills_vs_trades.sql) puts each fill next to the
public trade that [market-data](https://github.com/winterchill-trading/market-data)
recorded for it (its `parquet/trades` tables, written by `market-recorder` or
`market-data day-close`): the same trade id, or else the same price, enough size, the
taker on the other side and the nearest exchange time within 2 s. It reports the
exchange time difference and how much earlier the private fill reached the maker than
the public trade reached the recorder, then a per-instrument summary:

```sh
{ echo "SET VARIABLE order_log = 'orders.csv';"
  echo "SET VARIABLE trades = '/data/md/binance/BTCUSDT/parquet/trades/*.parquet';"
  cat queries/fills_vs_trades.sql; } | duckdb
```

```
venue,symbol,local_ts,venue_ts,side,price,size,is_maker,trade_id,public_trade_id,match,taker_side,exch_lag_ms,public_ms
binance,BTCUSDT,2027-01-15 08:00:01,2027-01-15 08:00:00.99,buy,99990.00000000,0.00200000,true,500,500,id,sell,0.0,3.0
binance,BTCUSDT,2027-01-15 08:00:02,2027-01-15 08:00:01.995,sell,100010.00000000,0.00100000,true,9001,777,nearest,buy,0.0,-2.0
binance,BTCUSDT,2027-01-15 08:00:03,2027-01-15 08:00:02.995,sell,100020.00000000,0.00100000,true,9002,NULL,NULL,NULL,NULL,NULL
venue,symbol,fills,matched,by_id,median_public_ms,max_exch_lag_ms
binance,BTCUSDT,3,2,1,0.5,0.0
```

(the test's data, `test/test_fills_vs_trades.ml`; the test needs the `duckdb` CLI on
`PATH` or in `/opt/homebrew/bin`). Hyperliquid fills carry the public trade id; where a
venue numbers private executions apart from public trades, the match falls back to
price and time.

### Status viewer (prototype)

`market-maker-status ORDER_LOG` is a terminal viewer built with
[Bonsai_term](https://github.com/janestreet/bonsai_term): it tails an order log (every
`-refresh-ms`, 250) and shows the resting orders, position, volume and fees from the
fills, counts per event, the request to answer latency and the latest fills; `q` quits.
It reads only the file, so it runs next to a live maker or on a finished run's log;
`-once` prints the same text and exits. On the 15 s binance-sim log above:

```
binance BTCUSDT  last row 438.5s ago
position -0.004  volume 5606.067 USD  fees 1.1212134 USD
place 116  ack 116  cancel 100  fill 28  update 232
ack latency median 0.62ms max 13.61ms (last 116)
resting orders (0)
recent fills
  439.2s ago  buy  0.002 @ 100136.2
  ...
```

The fold is `Market_maker.Order_log_status` and the file follower `Order_log_tail`, both
tested with the library. `bonsai_term` is on the OxCaml switch but is not a dependency of
the opam package: a dune `select` builds the terminal view (`bin/status_tui.bonsai.ml`)
where it is installed and a stub elsewhere (CI), where only `-once` works.

### Mirrors and reconnects

The shadow and the strategy log attach to the venue in the `on_venue` hook of
`Mm_core.Live.connect_and_start`, before the loop takes its first snapshots, and register
`Live.on_resync` hooks: on every venue reconnect their mirror strategies start the same
action rate grace period as the live loop (`Shadow.on_resync`, `Strategy_log.on_resync`,
at the time source's now), and the log gets a `(Resync (now <ns>))` line that `Replay.run`
feeds to `Mm_core.Strategy.on_resync`. Without that, the requote burst after a reconnect
halted the mirrors (and made a replay diverge) while the live loop kept quoting. A 30 s
`scripts/e2e-all.sh` run after the change: hyperliquid p50=40us p99=170us, binance
p50=56us p99=758us, bybit p50=41us p99=2.2ms, fault-binance p50=53us p99=677us (two
reconnects, ended `Running`), within run-to-run noise of the table below.

## Library

`Market_maker.Venues`: `Venue_choice.t = Hyperliquid | Binance | Bybit` and
`Network.t = Local | Testnet | Mainnet` (with `Command` arg types), and

```ocaml
module type RUNNER = sig
  val venue : Venue_choice.t
  val endpoint : string
  val min_notional : Symbol.t -> Usd.t option Or_error.t Deferred.t
  val connect_and_run
    :  ?time_source:Time_source.t
    -> ?reload:unit Pipe.Reader.t
    -> ?shadow_params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> ?strategy_log:string
    -> symbol:Symbol.t
    -> params:(Instrument.t -> mid:Price.t -> Mm_core.Params.t Or_error.t)
    -> summary_interval:Time_ns.Span.t
    -> stop:unit Deferred.t
    -> Session.Outcome.t Or_error.t Deferred.t
end

val runner : ?base_url:Uri.t -> ?address:string -> ?allow_mainnet:bool
  -> ?getenv:(string -> string option) -> Venue_choice.t -> network:Network.t -> (module RUNNER) Or_error.t
```

The other modules:

- `Session.Make (V)`: one run on a venue (`connect_and_run` above) over
  `Mm_core.Live.Make`; `Session.Outcome.t` is the live report, the tick-to-order stats,
  the number of reloads and the shadow counts.
- `Restartable_venue.Make (V)`: a `Venue.S` whose `close` does nothing, so a live loop can
  stop and a new one start on the same connection (`next_loop`, `shutdown`); observers
  see every value the strategy is fed (the shadow and the strategy log use them).
- `Params_file`: `apply` and `load` for the override files.
- `Shadow`: the shadow strategy and its plan comparison.
- `Strategy_input`, `Strategy_log`: the logged events, writer, loader and replay.
- `Order_event`, `Order_log`: the order lifecycle the venue wrapper observes, its CSV
  writer and row parser; `Order_log_status`: the summary the status viewer shows.
- `Cycle_monitor`: long Async cycles, counted and logged.

## End-to-end runs

```sh
scripts/e2e.sh binance            # 60 s against a seeded binance-sim on a free port
scripts/e2e.sh bybit 30 -levels 5 # seconds, then market-maker flags
FAULT_AT=10 scripts/e2e.sh hl 30  # restart hl-sim 10 s in, check the recovery
SIGNED=1 scripts/e2e.sh hl 15     # sign with a throwaway key, check hl-sim's journal
scripts/e2e-all.sh                # all three, then a fault run on binance
scripts/compare-venues.sh         # one order sequence on hl-sim and binance-sim, diffed
scripts/e2e-plausibility.sh       # frozen reference and toxic burst on an anchored hl-sim
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

With `SIGNED=1` (Hyperliquid only), `e2e.sh` sets `HL_PRIVATE_KEY` to a throwaway key
(the secp256k1 secret 1, address `0x7e5f4552091a69125d5dfcb7b8c2659029395bdf`), starts
hl-sim with `-journal`, and fails unless the maker logged `signed for testnet` and every
journalled order request carries a signature, for that account. A 15 s run placed 66
orders in 21 order requests, all signed. Without `SIGNED=1` the script clears
`HL_PRIVATE_KEY` and `HL_ADDRESS`, so a key in the environment never changes a run.

`e2e-all.sh` first prints the commit of every sibling checkout (`+dirty` with local
changes), runs the three venues, then the fault run on `FAULT_VENUE` (default `binance`,
`none` skips it) with the restart a third of the way in, and ends with a tick-to-order
table. The fault run uses the default cap of 100 actions per second. A freshly started
simulator's book jumps for its first seconds and the maker requotes on every jump; before
the action rate grace period that burst tripped a permanent halt (seen on all three
venues), so the run used to pass `-max-actions-per-sec 1000`. Now the reconnect starts a
5 s grace period (`-action-rate-grace-ms`) in which the burst is not counted.

`e2e-plausibility.sh` starts a reference hl-sim and a venue hl-sim whose BTC follows it
live (`-anchor hyperliquid:BTC -anchor-base-url`), and runs the maker on the venue for 75
s with `-reference anchor`, a VPIN signal (buckets of 0.05 BTC, window 10, `vpin`) and a
params file turning on the guard (2 s maximum reference age) and the gate (widen from
0.65, pull at 0.85). 15 s in it pauses the reference simulator for 8 s (SIGSTOP, then
SIGCONT); 35 s in it sends 100 IOC buys of 0.02 BTC, one every 0.1 s. From the order log
it checks that the guard pulled (`reference_missing`) and resumed after the thaw with no
`place` row in between, and that the gate widened, with quotes still placed, before it
pulled, and placed nothing while pulled. Two runs on one machine (2026-10-16): the guard
pulled 4 s after the pause (2 s for the venue's anchor to go stale, 2 s of reference age)
and resumed 0.3 s after the thaw; VPIN went from about 0.45 to 0.67 (widening) 2 s into
the burst and to 0.87 (pulled) 6 to 10 s in, and the gate cleared about 10 s after the
burst. Its thresholds are set for this simulator's mixed flow, whose VPIN wanders between
0.4 and 0.6; with half the burst size VPIN peaked at 0.8 and the run failed.

Fault runs of 30 s with the restart 10 s in, default cap, grace period off and on:

| Venue | `-action-rate-grace-ms 0` | default (5000) |
| --- | --- | --- |
| hyperliquid | Running (1 reconnect) | Running (1 reconnect) |
| binance | Running (2 reconnects) | Running (2 reconnects) |
| bybit | `Halted (Max_action_rate (actions 103))`, fault check fails | Running (2 reconnects) |

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

The same run after the grace period and in-place params reloads, with the fault run at
the default action rate cap (it reconnected twice and ended `Running`):

```
--- tick-to-order latency ---
hyperliquid    n=52 p50=61us p99=291us max=291us
binance        n=69 p50=58us p99=1.5ms max=1.5ms
bybit          n=67 p50=60us p99=2.1ms max=2.1ms
fault-binance  n=47 p50=67us p99=689us max=689us
```

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
shadow plans, a strategy log that replays to the same plans, and a reconnect followed by
a requote burst that halts neither the loop nor its mirrors (and does halt both without
the reconnect's grace period). A signed Hyperliquid run (`HL_PRIVATE_KEY` set to a
throwaway key) quotes on an in-process hl-sim whose clock is the test's synthetic one; the
test recovers the signer of every journalled request: the maker's orders and cancels are
signed by the key, for the key's account. `Params_file`, `Shadow`,
`Strategy_log`, `Restartable_venue`, `Order_log`, `Order_log_status`, `Reference_source`,
`Toxicity_source` and `Cycle_monitor` have their own tests; a session with a reference
pipe pulls on a 50 bps divergence and on a frozen reference and resumes, and one with a
toxicity pipe widens, pulls and clears; a session writes an order log (places, acks, a fill, the final
cancel-all) and counts a cycle that blocks the scheduler for 60 ms;
`queries/fills_vs_trades.sql` runs through the `duckdb` CLI (CI installs it).

### Nightly

`.github/workflows/nightly.yml` builds and tests against the current `main` of every pin
each night (the push CI does the same, but only when this repository changes), and on
Mondays runs `scripts/e2e-all.sh 30` in a workspace of this checkout and the three
simulators (the other siblings come from the pinned switch). The latency and long cycle
tables go to the job summary and, with every log and report, to an `e2e-all-<run id>`
artifact kept for 30 days. `workflow_dispatch` runs both. The first run (dispatched, 23 minutes
with the switch build) passed on an `ubuntu-latest` runner: tick-to-order p50 46 to 48
us, p99 458 us (hyperliquid) to 1.9 ms (bybit), no Async cycle over 20 ms. The adapters' own test
suites run the strategy on each simulator.
