-- Q2 Mobile-app wallet statement: last 20 ledger lines for one customer's NGN wallet
SELECT le.entry_id, le.created_at, t.txn_type, le.direction, le.amount, le.balance_after
FROM fx.ledger_entries le
JOIN fx.transactions t USING (txn_id)
WHERE le.wallet_id = (SELECT wallet_id FROM fx.wallets WHERE customer_id = 777 AND currency_code = 'NGN')
ORDER BY le.created_at DESC
LIMIT 20;
