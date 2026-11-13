-- Portfolio 1 evidence: every test below is EXPECTED to be rejected (or succeed where noted).
-- Run: psql -d nairalink -f 03_constraint_tests.sql   (errors are expected; ON_ERROR_STOP is off)
SET search_path = fx, public;
\echo '--- Setup: one customer + two wallets (house account is customer 1) ---'
INSERT INTO customers(email,phone,full_name,kyc_tier) VALUES ('house@nairalink.example','+2340000000000','NairaLink House Float',3);
INSERT INTO customers(email,phone,full_name,kyc_tier) VALUES ('ada@example.com','+2348011111111','Ada Obi',1);
INSERT INTO wallets(customer_id,currency_code,balance) VALUES (2,'NGN',100000),(2,'USD',0);
INSERT INTO wallets(customer_id,currency_code,balance,wallet_type) VALUES (1,'NGN',1000000000,'SETTLEMENT');

\echo '--- T1 duplicate email (UNIQUE) -> expect ERROR ---'
INSERT INTO customers(email,phone,full_name) VALUES ('ada@example.com','+2348022222222','Dup');
\echo '--- T2 invalid email format (CHECK) -> expect ERROR ---'
INSERT INTO customers(email,phone,full_name) VALUES ('not-an-email','+2348033333333','Bad Email');
\echo '--- T3 unknown KYC tier (FK) -> expect ERROR ---'
INSERT INTO customers(email,phone,full_name,kyc_tier) VALUES ('x@example.com','+2348044444444','X',9);
\echo '--- T4 second NGN wallet for same customer (UNIQUE customer+currency) -> expect ERROR ---'
INSERT INTO wallets(customer_id,currency_code) VALUES (2,'NGN');
\echo '--- T5 overdraft: customer balance would go negative (chk_no_overdraft) -> expect ERROR ---'
UPDATE wallets SET balance = balance - 999999 WHERE wallet_id = 1;
\echo '--- T6 held amount > balance (chk_hold_le_balance) -> expect ERROR ---'
UPDATE wallets SET held_amount = 200000 WHERE wallet_id = 1;
\echo '--- T7 rate with ask < bid (CHECK) -> expect ERROR ---'
INSERT INTO fx_rates(base_ccy,quote_ccy,bid,ask,lp_id,captured_at) VALUES ('USD','NGN',1500,1490,1,now());
\echo '--- T8 pair with same base/quote -> expect ERROR ---'
INSERT INTO fx_rates(base_ccy,quote_ccy,bid,ask,lp_id,captured_at) VALUES ('USD','USD',1,1,1,now());
\echo '--- T9 delete customer who owns wallets (ON DELETE RESTRICT) -> expect ERROR ---'
DELETE FROM customers WHERE customer_id = 2;
\echo '--- T10 UNBALANCED ledger (deferred trigger fires at COMMIT) -> expect ERROR ---'
BEGIN;
INSERT INTO transactions(reference,txn_type,customer_id,status) VALUES ('T10-BAD','FUNDING',2,'SUCCESS');
INSERT INTO ledger_entries(txn_id,wallet_id,direction,amount,balance_after)
   SELECT currval(pg_get_serial_sequence('fx.transactions','txn_id')),1,'CR',500,100500;  -- no matching DR
COMMIT;   -- <- rejected here
\echo '--- T10b VALID balanced funding (house DR / customer CR) -> expect COMMIT ok ---'
BEGIN;
INSERT INTO transactions(reference,txn_type,customer_id,status) VALUES ('T10-GOOD','FUNDING',2,'SUCCESS');
INSERT INTO ledger_entries(txn_id,wallet_id,direction,amount,balance_after)
   SELECT currval(pg_get_serial_sequence('fx.transactions','txn_id')),3,'DR',500,999999500;
INSERT INTO ledger_entries(txn_id,wallet_id,direction,amount,balance_after)
   SELECT currval(pg_get_serial_sequence('fx.transactions','txn_id')),1,'CR',500,100500;
COMMIT;
SELECT txn_id, wallet_id, direction, amount FROM ledger_entries ORDER BY entry_id;
\echo '--- T11 UPDATE on immutable ledger -> expect ERROR ---'
UPDATE ledger_entries SET amount = 1;
\echo '--- T12 audit trigger: change KYC tier, then read audit_log -> expect 1 row ---'
UPDATE customers SET kyc_tier = 2 WHERE customer_id = 2;
SELECT table_name, operation, old_data->>'kyc_tier' AS old_tier, new_data->>'kyc_tier' AS new_tier FROM audit_log;
\echo '--- T13 wallet version bump trigger (optimistic locking) -> version 0 -> 1 ---'
UPDATE wallets SET balance = balance + 10 WHERE wallet_id = 1;
SELECT wallet_id, balance, version FROM wallets WHERE wallet_id = 1;
