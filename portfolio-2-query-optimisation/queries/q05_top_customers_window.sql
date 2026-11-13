-- Q5 Top 5 converters per KYC tier in the last 90 days (CTE + window function RANK)
WITH vol AS (
  SELECT o.customer_id, sum(o.sell_amount) AS ngn_sold, count(*) AS n_orders
  FROM fx.fx_orders o
  WHERE o.placed_at >= now() - interval '90 days'
  GROUP BY o.customer_id
), ranked AS (
  SELECT c.kyc_tier, c.customer_id, c.full_name, v.ngn_sold, v.n_orders,
         RANK() OVER (PARTITION BY c.kyc_tier ORDER BY v.ngn_sold DESC) AS rnk
  FROM vol v JOIN fx.customers c USING (customer_id)
)
SELECT * FROM ranked WHERE rnk <= 5 ORDER BY kyc_tier, rnk;
