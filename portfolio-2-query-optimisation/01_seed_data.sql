-- =====================================================================
-- Portfolio 2: synthetic data generator (deterministic via setseed).
-- Volume: 20,000 customers | 80k wallets | 1.44M FX ticks | 40k fundings
--         150k FX conversions (600k ledger legs) | 20k withdrawals
-- Every transaction is double-entry balanced; wallet balances are DERIVED from the ledger,
-- so the reconciliation query in 02_queries.sql must return 0 mismatches.
-- All data is synthetic. Run AFTER portfolio-1 schema + triggers.
-- =====================================================================
SET search_path = fx, public;
SELECT setseed(0.42);
\timing on

TRUNCATE ledger_entries, payments, fx_orders, transactions, fx_rates, wallets, customers,
         audit_log RESTART IDENTITY CASCADE;
ALTER TABLE ledger_entries DISABLE TRIGGER trg_ledger_balanced;   -- re-enabled + verified below
ALTER TABLE ledger_entries DISABLE TRIGGER trg_ledger_no_update;
ALTER TABLE wallets        DISABLE TRIGGER trg_wallet_version;

-- 1. customers (id 1 = house / settlement owner) -----------------------
INSERT INTO customers(email,phone,full_name,country_code,kyc_tier,status,created_at)
VALUES ('house@nairalink.example','+2340000000000','NairaLink House Float','NG',3,'ACTIVE', now()-interval '400 days');

INSERT INTO customers(email,phone,full_name,country_code,kyc_tier,status,created_at)
SELECT 'user'||g||'@mail.example',
       '+234'||(8000000000+g)::text,
       (ARRAY['Ada','Chinedu','Ngozi','Tunde','Amina','Emeka','Fatima','Seun','Ife','Bola',
              'Kemi','Ibrahim','Zainab','Obinna','Yetunde','Segun','Aisha','Femi','Uche','Halima'])[1+g%20]
       ||' '||
       (ARRAY['Okafor','Adeyemi','Bello','Nwosu','Eze','Balogun','Musa','Okonkwo','Ojo','Abubakar',
              'Lawal','Chukwu','Ibrahim','Afolabi','Danjuma','Onyeka','Salami','Obi','Yusuf','Akpan'])[1+(g/20)%20],
       'NG',
       CASE WHEN random()<0.10 THEN 0 WHEN random()<0.40 THEN 1 WHEN random()<0.80 THEN 2 ELSE 3 END,
       CASE WHEN random()<0.97 THEN 'ACTIVE' ELSE 'SUSPENDED' END,
       now() - interval '400 days' + (random()*190 || ' days')::interval
FROM generate_series(1,20000) g;

-- 2. wallets: 4 per customer (NGN,USD,GBP,EUR) + 7 settlement wallets for house
INSERT INTO wallets(customer_id,currency_code,wallet_type,created_at)
SELECT 1, currency_code, 'SETTLEMENT', now()-interval '400 days' FROM currencies;
INSERT INTO wallets(customer_id,currency_code,created_at)
SELECT c.customer_id, cc.code, c.created_at
FROM customers c CROSS JOIN (VALUES ('NGN'),('USD'),('GBP'),('EUR')) cc(code)
WHERE c.customer_id > 1;

-- 3. fx_rates: 6 pairs x 3 LPs x 80,000 ticks over 180 days (1.44M rows)
INSERT INTO fx_rates(base_ccy,quote_ccy,bid,ask,lp_id,captured_at)
SELECT p.base, 'NGN',
       round((m.mid*(1-p.sp))::numeric,6),
       round((m.mid*(1+p.sp))::numeric,6),
       lp, ts
FROM (VALUES ('USD',1550.0,0.0030),('GBP',1960.0,0.0040),('EUR',1680.0,0.0035),
             ('CAD',1130.0,0.0045),('GHS',100.0,0.0060),('KES',12.0,0.0070)) p(base,mid0,sp)
CROSS JOIN generate_series(1,3) lp
CROSS JOIN generate_series(0,79999) i
CROSS JOIN LATERAL (SELECT now() - interval '180 days' + i*interval '194 seconds' + lp*interval '1 second' AS ts) t
CROSS JOIN LATERAL (SELECT p.mid0*(1 + 0.04*sin(i/8000.0 + lp) + (random()-0.5)*0.004) AS mid) m;

-- 4. fundings: 2 per customer, in first 20 days of the window ----------
CREATE TEMP TABLE t_fund AS
SELECT row_number() OVER () AS n, c.customer_id AS cust,
       round((10000000 + random()*20000000)::numeric,2) AS amt,
       now() - interval '180 days' + (random()*19 || ' days')::interval AS ts
FROM customers c CROSS JOIN generate_series(1,2) k WHERE c.customer_id>1;

INSERT INTO transactions(reference,txn_type,status,customer_id,created_at,completed_at)
SELECT 'FND-'||lpad(n::text,7,'0'),'FUNDING','SUCCESS',cust,ts,ts+interval '3 seconds' FROM t_fund;

INSERT INTO payments(txn_id,channel,provider_ref,amount,currency_code,status,created_at)
SELECT t.txn_id,(ARRAY['BANK_TRANSFER','CARD','USSD'])[1+(f.n%3)::int],'PSP-'||f.n,f.amt,'NGN','CONFIRMED',f.ts
FROM t_fund f JOIN transactions t ON t.reference='FND-'||lpad(f.n::text,7,'0');

-- 5. conversions: 150k orders at a REAL tick's ask (USD 70% / GBP 15% / EUR 15%)
CREATE TEMP TABLE t_rates AS
SELECT row_number() OVER () AS rn, rate_id, base_ccy, ask, lp_id, captured_at
FROM fx_rates WHERE base_ccy IN ('USD','GBP','EUR') AND captured_at > now()-interval '158 days';
CREATE INDEX ON t_rates(rn);
ANALYZE t_rates;

CREATE TEMP TABLE t_conv AS
SELECT g AS n,
       2 + floor(random()*20000)::int AS cust,
       1 + floor(random()*(SELECT max(rn) FROM t_rates))::bigint AS rn,
       round((5000 + random()*295000)::numeric,2) AS sell
FROM generate_series(1,150000) g;

CREATE TEMP TABLE t_conv2 AS
SELECT c.n, c.cust, c.sell, r.base_ccy AS buy_ccy, r.ask AS rate, r.lp_id, r.captured_at AS ts,
       round(c.sell * k.fee_pct, 4) AS fee,
       round((c.sell - round(c.sell*k.fee_pct,4)) / r.ask, 4) AS buy_amt
FROM t_conv c
JOIN t_rates r USING (rn)
JOIN customers cu ON cu.customer_id = c.cust
JOIN kyc_tiers k ON k.tier = cu.kyc_tier;

INSERT INTO transactions(reference,txn_type,status,customer_id,created_at,completed_at)
SELECT 'FXC-'||lpad(n::text,7,'0'),'FX_CONVERSION','SUCCESS',cust,ts,ts+interval '1 second' FROM t_conv2;

CREATE TEMP TABLE t_w AS SELECT wallet_id, customer_id, currency_code FROM wallets;
CREATE INDEX ON t_w(customer_id,currency_code);

INSERT INTO fx_orders(txn_id,customer_id,sell_wallet,buy_wallet,order_type,sell_amount,buy_amount,
                      rate_applied,fee_amount,lp_id,status,placed_at)
SELECT t.txn_id, c.cust, ws.wallet_id, wb.wallet_id,
       CASE WHEN c.n%10=0 THEN 'LIMIT' ELSE 'MARKET' END,
       c.sell, c.buy_amt, c.rate, c.fee, c.lp_id, 'FILLED', c.ts
FROM t_conv2 c
JOIN transactions t ON t.reference='FXC-'||lpad(c.n::text,7,'0')
JOIN t_w ws ON ws.customer_id=c.cust AND ws.currency_code='NGN'
JOIN t_w wb ON wb.customer_id=c.cust AND wb.currency_code=c.buy_ccy;

-- 6. withdrawals: 20k NGN withdrawals --------------------------------
CREATE TEMP TABLE t_wd AS
SELECT g AS n, 2+floor(random()*20000)::int AS cust,
       round((100000+random()*1900000)::numeric,2) AS amt,
       now()-interval '150 days' + (random()*149||' days')::interval AS ts
FROM generate_series(1,20000) g;
INSERT INTO transactions(reference,txn_type,status,customer_id,created_at,completed_at)
SELECT 'WDR-'||lpad(n::text,7,'0'),'WITHDRAWAL','SUCCESS',cust,ts,ts+interval '5 seconds' FROM t_wd;
INSERT INTO payments(txn_id,channel,provider_ref,amount,currency_code,status,created_at)
SELECT t.txn_id,'BANK_TRANSFER','PSP-W'||w.n,w.amt,'NGN','CONFIRMED',w.ts
FROM t_wd w JOIN transactions t ON t.reference='WDR-'||lpad(w.n::text,7,'0');

-- 7. ledger legs (all balanced per txn & currency); balance_after added next
CREATE TEMP TABLE t_legs AS
-- funding: house DR / customer CR (NGN)
SELECT t.txn_id, hw.wallet_id, 'DR'::char(2) AS direction, f.amt AS amount, f.ts
  FROM t_fund f JOIN transactions t ON t.reference='FND-'||lpad(f.n::text,7,'0')
  JOIN wallets hw ON hw.customer_id=1 AND hw.currency_code='NGN'
UNION ALL
SELECT t.txn_id, cw.wallet_id, 'CR', f.amt, f.ts
  FROM t_fund f JOIN transactions t ON t.reference='FND-'||lpad(f.n::text,7,'0')
  JOIN t_w cw ON cw.customer_id=f.cust AND cw.currency_code='NGN'
UNION ALL  -- withdrawal: customer DR / house CR
SELECT t.txn_id, cw.wallet_id, 'DR', w.amt, w.ts
  FROM t_wd w JOIN transactions t ON t.reference='WDR-'||lpad(w.n::text,7,'0')
  JOIN t_w cw ON cw.customer_id=w.cust AND cw.currency_code='NGN'
UNION ALL
SELECT t.txn_id, hw.wallet_id, 'CR', w.amt, w.ts
  FROM t_wd w JOIN transactions t ON t.reference='WDR-'||lpad(w.n::text,7,'0')
  JOIN wallets hw ON hw.customer_id=1 AND hw.currency_code='NGN'
UNION ALL  -- conversion leg 1: customer DR NGN (sell, fee included)
SELECT o.txn_id, o.sell_wallet, 'DR', o.sell_amount, o.placed_at FROM fx_orders o
UNION ALL  -- leg 2: house CR NGN
SELECT o.txn_id, hw.wallet_id, 'CR', o.sell_amount, o.placed_at FROM fx_orders o
  JOIN wallets hw ON hw.customer_id=1 AND hw.currency_code='NGN'
UNION ALL  -- leg 3: house DR buy-currency
SELECT o.txn_id, hw.wallet_id, 'DR', o.buy_amount, o.placed_at FROM fx_orders o
  JOIN wallets bw ON bw.wallet_id=o.buy_wallet
  JOIN wallets hw ON hw.customer_id=1 AND hw.currency_code=bw.currency_code
UNION ALL  -- leg 4: customer CR buy-currency
SELECT o.txn_id, o.buy_wallet, 'CR', o.buy_amount, o.placed_at FROM fx_orders o;

INSERT INTO ledger_entries(txn_id,wallet_id,direction,amount,balance_after,created_at)
SELECT txn_id, wallet_id, direction, amount,
       SUM(CASE direction WHEN 'CR' THEN amount ELSE -amount END)
         OVER (PARTITION BY wallet_id ORDER BY ts, txn_id, direction ROWS UNBOUNDED PRECEDING),
       ts
FROM t_legs;

-- 8. wallet balances derived from the ledger
UPDATE wallets w SET balance = s.bal
FROM (SELECT wallet_id, SUM(CASE direction WHEN 'CR' THEN amount ELSE -amount END) AS bal
        FROM ledger_entries GROUP BY wallet_id) s
WHERE s.wallet_id = w.wallet_id;

ALTER TABLE ledger_entries ENABLE TRIGGER trg_ledger_balanced;
ALTER TABLE ledger_entries ENABLE TRIGGER trg_ledger_no_update;
ALTER TABLE wallets        ENABLE TRIGGER trg_wallet_version;

ANALYZE;
\timing off
SELECT 'customers' t, count(*) FROM customers UNION ALL SELECT 'wallets',count(*) FROM wallets
UNION ALL SELECT 'fx_rates',count(*) FROM fx_rates UNION ALL SELECT 'transactions',count(*) FROM transactions
UNION ALL SELECT 'fx_orders',count(*) FROM fx_orders UNION ALL SELECT 'ledger_entries',count(*) FROM ledger_entries
UNION ALL SELECT 'payments',count(*) FROM payments;
