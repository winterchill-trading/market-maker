(lang dune 3.17)

(name market-maker)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/market-maker))

(package
 (name market-maker)
 (synopsis "Multi-venue market maker: the mm-core strategy on Hyperliquid, Binance or Bybit")
 (depends
  ocaml
  dune
  core
  core_unix
  async
  exchange-core
  mm-core
  hl-protocol
  hl-client
  hl-mm
  binance-protocol
  binance-client
  bybit-protocol
  bybit-client
  ppx_jane
  uri
  (cohttp-async :with-test)
  (hl-sim :with-test)))
