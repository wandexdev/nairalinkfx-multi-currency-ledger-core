-- Q6 USD/NGN daily average mid-rate with a 7-day moving average (analytic window frame)
WITH daily AS (
  SELECT date_trunc('day', captured_at)::date AS day, avg((bid+ask)/2) AS mid
  FROM fx.fx_rates
  WHERE base_ccy = 'USD' AND quote_ccy = 'NGN' AND lp_id = 1
    AND captured_at >= now() - interval '60 days'
  GROUP BY 1
)
SELECT day, round(mid,2) AS mid,
       round(avg(mid) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),2) AS ma7
FROM daily ORDER BY day DESC LIMIT 14;
