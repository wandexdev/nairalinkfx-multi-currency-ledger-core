-- Q1b Same answer as Q1a, rewritten as one LIMIT-1 index probe per liquidity provider (LATERAL "loose index scan")
SELECT lp.lp_id, r.bid, r.ask, r.captured_at
FROM fx.liquidity_providers lp
CROSS JOIN LATERAL (
    SELECT bid, ask, captured_at FROM fx.fx_rates
    WHERE base_ccy = 'USD' AND quote_ccy = 'NGN' AND lp_id = lp.lp_id
    ORDER BY captured_at DESC LIMIT 1
) r
ORDER BY lp.lp_id;
