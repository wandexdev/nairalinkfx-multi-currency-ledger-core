-- Portfolio 2: indexes added AFTER baseline measurement (each justified in analysis.md)
SET search_path = fx, public;
-- Q1/Q6: equality on pair+LP then range/sort on time (latest-row & time-window lookups)
CREATE INDEX idx_fx_rates_pair_lp_time ON fx_rates (base_ccy, quote_ccy, lp_id, captured_at DESC);
-- Q2: statement = one wallet, newest first, LIMIT. Index order matches ORDER BY -> no sort
CREATE INDEX idx_ledger_wallet_time ON ledger_entries (wallet_id, created_at DESC);
-- Q3: one customer + time range (also supports FK joins from customer)
CREATE INDEX idx_orders_customer_time ON fx_orders (customer_id, placed_at DESC);
-- Q4/Q5/Q8: time-range scans over recent orders; INCLUDE makes them index-only-friendly
CREATE INDEX idx_orders_time_cover ON fx_orders (placed_at DESC) INCLUDE (customer_id, buy_wallet, sell_amount, fee_amount);
-- FK-support indexes (Postgres does not auto-index FKs; avoids seq scans on joins / deletes)
CREATE INDEX idx_ledger_txn   ON ledger_entries (txn_id);
CREATE INDEX idx_wallet_cust  ON wallets (customer_id);
ANALYZE;
