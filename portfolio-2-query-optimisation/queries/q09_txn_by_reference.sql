-- Q9 Support/idempotency lookup by external reference (UNIQUE index already exists -> control query)
SELECT txn_id, txn_type, status, customer_id, created_at FROM fx.transactions WHERE reference = 'FXC-0054321';
