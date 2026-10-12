-- The maker's fills from an order log (market-maker -order-log) next to the public trades
-- that market-data recorded for the same venue and symbol.
--
-- Set two variables first, then run this file:
--
--   SET VARIABLE order_log = 'orders.csv';
--   SET VARIABLE trades = '/data/md/*/*/parquet/trades/*.parquet';
--
-- Each fill is matched to the public trade with the same trade id or, when the venue
-- numbers private and public trades apart, with the same price, a size at least the
-- fill's, the taker on the other side for a maker fill, and the nearest exchange time
-- within 2 seconds. Columns:
--
--   exch_lag_ms   public trade exch_ts - fill venue_ts (exchange clock)
--   public_ms     public trade recv_ts - fill local_ts: positive when the private fill
--                 reached the maker before the public trade reached the recorder (two
--                 local clocks; meaningful when both run on one host)
--   match         'id', 'nearest' or NULL (no public trade found)
--
-- A second statement summarises per venue and symbol.

CREATE OR REPLACE TEMP VIEW fills AS
SELECT
  venue,
  symbol,
  make_timestamp_ns(local_ts::BIGINT) AS local_ts,
  make_timestamp_ns(venue_ts::BIGINT) AS venue_ts,
  side,
  price::DECIMAL(18, 8) AS price,
  size::DECIMAL(18, 8) AS size,
  order_id,
  trade_id,
  status = 'maker' AS is_maker,
  fee::DECIMAL(18, 8) AS fee
FROM read_csv(getvariable('order_log'), header = true, all_varchar = true)
WHERE event = 'fill';

CREATE OR REPLACE TEMP VIEW fills_vs_trades AS
WITH
  public_trades AS (
    SELECT venue, symbol, exch_ts, recv_ts, price, size, side, trade_id
    FROM read_parquet(getvariable('trades'), hive_partitioning = false)
  ),
  candidates AS (
    SELECT
      f.*,
      t.trade_id AS public_trade_id,
      t.exch_ts,
      t.recv_ts,
      t.side AS taker_side,
      CASE WHEN t.trade_id = f.trade_id THEN 'id' ELSE 'nearest' END AS match,
      row_number() OVER (
        PARTITION BY f.venue, f.symbol, f.trade_id
        ORDER BY
          (t.trade_id = f.trade_id) DESC,
          abs(epoch_ns(t.exch_ts) - epoch_ns(f.venue_ts))
      ) AS rank
    FROM fills f
    LEFT JOIN public_trades t
      ON t.venue = f.venue
      AND t.symbol = f.symbol
      AND (
        t.trade_id = f.trade_id
        OR (
          t.price = f.price
          AND t.size >= f.size
          AND (NOT f.is_maker OR t.side <> f.side)
          AND abs(epoch_ns(t.exch_ts) - epoch_ns(f.venue_ts)) <= 2000000000
        )
      )
  )
SELECT
  venue,
  symbol,
  local_ts,
  venue_ts,
  side,
  price,
  size,
  is_maker,
  trade_id,
  public_trade_id,
  CASE WHEN public_trade_id IS NULL THEN NULL ELSE match END AS match,
  taker_side,
  (epoch_ns(exch_ts) - epoch_ns(venue_ts)) / 1e6 AS exch_lag_ms,
  (epoch_ns(recv_ts) - epoch_ns(local_ts)) / 1e6 AS public_ms
FROM candidates
WHERE rank = 1
ORDER BY venue, symbol, local_ts;

SELECT * FROM fills_vs_trades;

SELECT
  venue,
  symbol,
  count(*) AS fills,
  count(public_trade_id) AS matched,
  count(*) FILTER (WHERE match = 'id') AS by_id,
  round(median(public_ms), 3) AS median_public_ms,
  round(max(abs(exch_lag_ms)), 3) AS max_exch_lag_ms
FROM fills_vs_trades
GROUP BY ALL
ORDER BY ALL;
