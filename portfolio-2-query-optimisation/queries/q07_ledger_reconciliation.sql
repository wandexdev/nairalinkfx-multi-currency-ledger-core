-- Q7 Finance audit: every wallet balance must equal SUM(CR)-SUM(DR) of its ledger lines (expect 0 rows)
SELECT w.wallet_id, w.balance, l.ledger_balance
FROM fx.wallets w
JOIN (SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) AS ledger_balance
        FROM fx.ledger_entries GROUP BY wallet_id) l USING (wallet_id)
WHERE w.balance <> l.ledger_balance;
