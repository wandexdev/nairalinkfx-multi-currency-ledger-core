-- Q1a (naive version) Latest USD/NGN quote from each liquidity provider (hot path: every conversion needs this)
SELECT DISTINCT ON (lp_id) lp_id, bid, ask, captured_at
FROM fx.fx_rates
WHERE base_ccy = 'USD' AND quote_ccy = 'NGN'
ORDER BY lp_id, captured_at DESC;
