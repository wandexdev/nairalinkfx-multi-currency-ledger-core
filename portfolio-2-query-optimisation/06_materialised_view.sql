-- Portfolio 2: pre-aggregated daily volume (refresh nightly / after each batch). Trade-off: stale until refreshed.
SET search_path = fx, public;
DROP MATERIALIZED VIEW IF EXISTS mv_daily_volume;
CREATE MATERIALIZED VIEW mv_daily_volume AS
SELECT date_trunc('day', o.placed_at)::date AS day, w.currency_code AS bought_ccy,
       count(*) AS orders, sum(o.sell_amount) AS ngn_volume, sum(o.fee_amount) AS fee_revenue
FROM fx_orders o JOIN wallets w ON w.wallet_id = o.buy_wallet
GROUP BY 1, 2;
CREATE UNIQUE INDEX ON mv_daily_volume (day, bought_ccy);   -- enables REFRESH ... CONCURRENTLY
ANALYZE mv_daily_volume;
