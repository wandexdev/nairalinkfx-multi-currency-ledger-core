-- AFTER_ONLY
-- Q4b Same dashboard answer read from the pre-aggregated materialised view (needs 06_materialised_view.sql)
SELECT day, bought_ccy, orders, ngn_volume, fee_revenue
FROM fx.mv_daily_volume
WHERE day >= (now() - interval '30 days')::date
ORDER BY day DESC, bought_ccy;
