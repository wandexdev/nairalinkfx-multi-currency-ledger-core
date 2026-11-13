-- Q8 Compliance: customers who converted >= 80% of their tier's daily NGN limit on any single day, last 30 days
SELECT c.customer_id, c.kyc_tier, d.day, d.ngn_sold, k.daily_limit_ngn
FROM (SELECT customer_id, date_trunc('day', placed_at)::date AS day, sum(sell_amount) AS ngn_sold
        FROM fx.fx_orders WHERE placed_at >= now() - interval '30 days'
        GROUP BY 1, 2) d
JOIN fx.customers c USING (customer_id)
JOIN fx.kyc_tiers k ON k.tier = c.kyc_tier
WHERE d.ngn_sold >= 0.8 * k.daily_limit_ngn
ORDER BY d.ngn_sold DESC
LIMIT 20;
