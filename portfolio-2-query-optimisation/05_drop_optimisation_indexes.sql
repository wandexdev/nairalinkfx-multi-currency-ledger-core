SET search_path = fx, public;
DROP INDEX IF EXISTS idx_fx_rates_pair_lp_time, idx_ledger_wallet_time, idx_orders_customer_time,
                     idx_orders_time_cover, idx_ledger_txn, idx_wallet_cust;
ANALYZE;
