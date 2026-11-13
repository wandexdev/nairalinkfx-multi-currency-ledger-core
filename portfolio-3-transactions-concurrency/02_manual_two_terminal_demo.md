# Two-terminal manual demos (psql) - reproduce these yourself to be able to explain them

Open two terminals, `psql -d nairalink` in each (call them **T1** and **T2**). Use a scratch wallet:
```sql
-- either terminal, once
INSERT INTO fx.customers(email,phone,full_name,kyc_tier) VALUES ('demo@x.example','+2349999999999','Demo',2);
INSERT INTO fx.wallets(customer_id,currency_code,balance) SELECT customer_id,'NGN',1000 FROM fx.customers WHERE email='demo@x.example';
```
(Clean up afterwards: delete the wallet and customer.)

## 1. Lost update (READ COMMITTED)
| Step | T1 | T2 |
|---|---|---|
| 1 | `BEGIN; SELECT balance FROM fx.wallets WHERE customer_id=<id>;` -> 1000 | |
| 2 | | `BEGIN; SELECT balance FROM fx.wallets WHERE customer_id=<id>;` -> 1000 |
| 3 | `UPDATE fx.wallets SET balance=900 WHERE customer_id=<id>; COMMIT;` | |
| 4 | | `UPDATE fx.wallets SET balance=900 WHERE customer_id=<id>; COMMIT;` (blocks until T1 commits) |
Result: 900, but two withdrawals of 100 should give 800. **Fix:** use `SELECT ... FOR UPDATE` in step 1/2, or `SET balance = balance - 100`.

## 2. Non-repeatable read
T1: `BEGIN ISOLATION LEVEL READ COMMITTED; SELECT balance ...;` T2: `UPDATE ... SET balance=balance+250; COMMIT;`
T1: `SELECT balance ...;` -> changed. Repeat with `BEGIN ISOLATION LEVEL REPEATABLE READ;` -> same value both times.

## 3. Deadlock
T1: `BEGIN; SELECT 1 FROM fx.wallets WHERE wallet_id=A FOR UPDATE;`
T2: `BEGIN; SELECT 1 FROM fx.wallets WHERE wallet_id=B FOR UPDATE;`
T1: `SELECT 1 FROM fx.wallets WHERE wallet_id=B FOR UPDATE;` (waits)
T2: `SELECT 1 FROM fx.wallets WHERE wallet_id=A FOR UPDATE;` -> after `deadlock_timeout` (1 s) one gets `ERROR: deadlock detected` (40P01).
**Fix:** always lock in ascending wallet_id (what `fx.convert_currency` does).

## 4. Write skew -> SERIALIZABLE
Both: `BEGIN ISOLATION LEVEL REPEATABLE READ;` sum today's withdrawals (0); each inserts a 3,000,000 withdrawal; both commit -> 6,000,000 > 5,000,000 limit.
Repeat with `ISOLATION LEVEL SERIALIZABLE`: second commit fails with `40001 could not serialize access`; the app retries, sees 3,000,000 and refuses.

## 5. See the locks
While T1 holds a row lock: `SELECT pid, locktype, mode, granted, relation::regclass FROM pg_locks WHERE relation='fx.wallets'::regclass;`
and `SELECT pid, state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE datname='nairalink';`
