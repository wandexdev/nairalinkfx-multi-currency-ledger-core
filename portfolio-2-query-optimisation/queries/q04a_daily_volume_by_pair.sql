-- Q4a (live aggregate) Treasury dashboard: daily converted volume (NGN) and order count per currency, last 30 days
SELECT date_trunc('day', o.placed_at)::date AS day, w.currency_code AS bought_ccy,
       count(*) AS orders, sum(o.sell_amount) AS ngn_volume, sum(o.fee_amount) AS fee_revenue
FROM fx.fx_orders o
JOIN fx.wallets w ON w.wallet_id = o.buy_wallet
WHERE o.placed_at >= now() - interval '30 days'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
