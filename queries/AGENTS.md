# queries: market-maker SQL

`fills_vs_trades.sql` joins the order log's fills to public trades in market-data's Parquet tables.
Matching is by trade id, else by price, size and side within 2 seconds.

Rules:

- Run it against a day directory with `DuckDB`; it reads Parquet globs, so check the empty-glob case.
- The match window is a decision: change it in the README too.
