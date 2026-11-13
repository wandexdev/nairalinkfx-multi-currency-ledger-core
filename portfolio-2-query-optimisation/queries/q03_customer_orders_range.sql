-- Q3 A customer's FX orders in the last 60 days (order-history screen / support lookup)
SELECT o.order_id, o.placed_at, w.currency_code AS bought, o.sell_amount, o.buy_amount, o.rate_applied, o.fee_amount
FROM fx.fx_orders o
JOIN fx.wallets w ON w.wallet_id = o.buy_wallet
WHERE o.customer_id = 777 AND o.placed_at >= now() - interval '60 days'
ORDER BY o.placed_at DESC;
