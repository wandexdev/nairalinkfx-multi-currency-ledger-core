-- =====================================================================
-- Portfolio 3: the atomic FX conversion (sell NGN, buy USD/GBP/EUR)
-- One call = one transaction: either ALL of {2 wallet updates, txn, order, 4 ledger legs} happen or NONE.
-- Concurrency design: wallets are locked with SELECT ... FOR UPDATE in ascending wallet_id order
-- (prevents deadlock between concurrent conversions); the customer's NGN wallet lock also serialises
-- that customer's daily-limit check (prevents limit bypass by parallel requests).
-- =====================================================================
SET search_path = fx, public;

CREATE OR REPLACE FUNCTION fx.convert_currency(
    p_customer  BIGINT,
    p_buy_ccy   CHAR(3),
    p_sell_ngn  NUMERIC,
    p_reference VARCHAR,
    p_max_quote_age INTERVAL DEFAULT '2 days')
RETURNS BIGINT LANGUAGE plpgsql SET search_path = fx, public AS $$
DECLARE
    v_existing  BIGINT;
    v_tier      SMALLINT;  v_status TEXT;  v_limit NUMERIC;  v_fee_pct NUMERIC;
    v_sell_w    BIGINT;    v_buy_w BIGINT; v_house_ngn BIGINT; v_house_buy BIGINT;
    v_rate      NUMERIC;   v_lp SMALLINT;  v_quote_ts TIMESTAMPTZ;
    v_fee       NUMERIC;   v_buy_amt NUMERIC;
    v_used      NUMERIC;   v_bal NUMERIC;  v_txn BIGINT;
    v_bal_buy   NUMERIC;   v_bal_h_ngn NUMERIC; v_bal_h_buy NUMERIC;
BEGIN
    IF p_sell_ngn <= 0 THEN RAISE EXCEPTION 'amount must be positive' USING ERRCODE='22023'; END IF;
    IF p_buy_ccy NOT IN ('USD','GBP','EUR') THEN RAISE EXCEPTION 'unsupported currency %', p_buy_ccy USING ERRCODE='22023'; END IF;

    -- 1. idempotency: same reference returns the original transaction, never double-posts
    SELECT txn_id INTO v_existing FROM transactions WHERE reference = p_reference;
    IF FOUND THEN RETURN v_existing; END IF;

    -- 2. customer eligibility (tier, status, fee)
    SELECT c.kyc_tier, c.status, k.daily_limit_ngn, k.fee_pct INTO v_tier, v_status, v_limit, v_fee_pct
      FROM customers c JOIN kyc_tiers k ON k.tier = c.kyc_tier WHERE c.customer_id = p_customer;
    IF NOT FOUND THEN RAISE EXCEPTION 'customer % not found', p_customer USING ERRCODE='P0002'; END IF;
    IF v_status <> 'ACTIVE' THEN RAISE EXCEPTION 'customer % is %', p_customer, v_status USING ERRCODE='P0001'; END IF;
    IF v_tier = 0 THEN RAISE EXCEPTION 'KYC tier 0 may not convert; complete verification' USING ERRCODE='P0001'; END IF;

    -- 3. quote (read BEFORE taking locks so locks are held as briefly as possible).
    --    One LIMIT-1 index probe per active LP (see Portfolio 2, Q1b) then pick the freshest / cheapest.
    SELECT r.ask, lp.lp_id, r.captured_at INTO v_rate, v_lp, v_quote_ts
      FROM liquidity_providers lp
      CROSS JOIN LATERAL (SELECT ask, captured_at FROM fx_rates
                           WHERE base_ccy = p_buy_ccy AND quote_ccy = 'NGN' AND lp_id = lp.lp_id
                           ORDER BY captured_at DESC LIMIT 1) r
     WHERE lp.is_active
     ORDER BY r.captured_at DESC, r.ask ASC LIMIT 1;
    IF v_rate IS NULL OR now() - v_quote_ts > p_max_quote_age THEN
        RAISE EXCEPTION 'stale or missing quote for %/NGN', p_buy_ccy USING ERRCODE='P0001'; END IF;

    -- 4. lock all four wallets in a fixed global order (ascending wallet_id) -> deadlock-free
    SELECT max(wallet_id) FILTER (WHERE customer_id=p_customer AND currency_code='NGN'),
           max(wallet_id) FILTER (WHERE customer_id=p_customer AND currency_code=p_buy_ccy),
           max(wallet_id) FILTER (WHERE customer_id=1 AND currency_code='NGN'),
           max(wallet_id) FILTER (WHERE customer_id=1 AND currency_code=p_buy_ccy)
      INTO v_sell_w, v_buy_w, v_house_ngn, v_house_buy
      FROM wallets WHERE (customer_id=p_customer AND currency_code IN ('NGN',p_buy_ccy))
                      OR (customer_id=1 AND currency_code IN ('NGN',p_buy_ccy));
    PERFORM 1 FROM wallets WHERE wallet_id IN (v_sell_w, v_buy_w, v_house_ngn, v_house_buy) ORDER BY wallet_id FOR UPDATE;

    -- re-check idempotency now that we hold the lock (a concurrent retry may have just committed)
    SELECT txn_id INTO v_existing FROM transactions WHERE reference = p_reference;
    IF FOUND THEN RETURN v_existing; END IF;

    -- 5. business rules: funds + daily limit (safe: we hold the customer's NGN wallet lock)
    SELECT balance INTO v_bal FROM wallets WHERE wallet_id = v_sell_w;
    IF v_bal < p_sell_ngn THEN
        RAISE EXCEPTION 'insufficient funds: balance % < %', v_bal, p_sell_ngn USING ERRCODE='P0001'; END IF;
    SELECT COALESCE(sum(sell_amount),0) INTO v_used FROM fx_orders
     WHERE customer_id = p_customer AND placed_at >= date_trunc('day', now()) AND status='FILLED';
    IF v_used + p_sell_ngn > v_limit THEN
        RAISE EXCEPTION 'daily limit exceeded: used % + % > %', v_used, p_sell_ngn, v_limit USING ERRCODE='P0001'; END IF;

    -- 6. pricing (fee is taken out of the sell amount)
    v_fee     := round(p_sell_ngn * v_fee_pct, 4);
    v_buy_amt := round((p_sell_ngn - v_fee) / v_rate, 4);
    IF v_buy_amt <= 0 THEN RAISE EXCEPTION 'amount too small' USING ERRCODE='22023'; END IF;

    -- 7. post everything
    INSERT INTO transactions(reference,txn_type,status,customer_id,completed_at)
         VALUES (p_reference,'FX_CONVERSION','SUCCESS',p_customer,now()) RETURNING txn_id INTO v_txn;
    INSERT INTO fx_orders(txn_id,customer_id,sell_wallet,buy_wallet,order_type,sell_amount,buy_amount,rate_applied,fee_amount,lp_id,status)
         VALUES (v_txn,p_customer,v_sell_w,v_buy_w,'MARKET',p_sell_ngn,v_buy_amt,v_rate,v_fee,v_lp,'FILLED');

    UPDATE wallets SET balance = balance - p_sell_ngn  WHERE wallet_id = v_sell_w   RETURNING balance INTO v_bal;
    UPDATE wallets SET balance = balance + v_buy_amt   WHERE wallet_id = v_buy_w    RETURNING balance INTO v_bal_buy;
    UPDATE wallets SET balance = balance + p_sell_ngn  WHERE wallet_id = v_house_ngn RETURNING balance INTO v_bal_h_ngn;
    UPDATE wallets SET balance = balance - v_buy_amt   WHERE wallet_id = v_house_buy RETURNING balance INTO v_bal_h_buy;

    INSERT INTO ledger_entries(txn_id,wallet_id,direction,amount,balance_after) VALUES
        (v_txn, v_sell_w,    'DR', p_sell_ngn, v_bal),
        (v_txn, v_house_ngn, 'CR', p_sell_ngn, v_bal_h_ngn),
        (v_txn, v_house_buy, 'DR', v_buy_amt,  v_bal_h_buy),
        (v_txn, v_buy_w,     'CR', v_buy_amt,  v_bal_buy);
    RETURN v_txn;
END $$;

-- Reversal: opposite legs, original untouched (history is immutable)
CREATE OR REPLACE FUNCTION fx.reverse_conversion(p_txn BIGINT, p_reference VARCHAR) RETURNS BIGINT LANGUAGE plpgsql SET search_path = fx, public AS $$
DECLARE v_new BIGINT; v_orig transactions%ROWTYPE; v_ord fx_orders%ROWTYPE; v_hn BIGINT; v_hb BIGINT; v_bc CHAR(3);
        b1 NUMERIC; b2 NUMERIC; b3 NUMERIC; b4 NUMERIC;
BEGIN
    SELECT * INTO v_orig FROM transactions WHERE txn_id = p_txn FOR UPDATE;
    IF NOT FOUND OR v_orig.txn_type <> 'FX_CONVERSION' THEN RAISE EXCEPTION 'not a conversion'; END IF;
    IF v_orig.status = 'REVERSED' THEN RAISE EXCEPTION 'already reversed'; END IF;
    SELECT * INTO v_ord FROM fx_orders WHERE txn_id = p_txn;
    SELECT currency_code INTO v_bc FROM wallets WHERE wallet_id = v_ord.buy_wallet;
    SELECT wallet_id INTO v_hn FROM wallets WHERE customer_id=1 AND currency_code='NGN';
    SELECT wallet_id INTO v_hb FROM wallets WHERE customer_id=1 AND currency_code=v_bc;
    PERFORM 1 FROM wallets WHERE wallet_id IN (v_ord.sell_wallet,v_ord.buy_wallet,v_hn,v_hb) ORDER BY wallet_id FOR UPDATE;
    INSERT INTO transactions(reference,txn_type,status,customer_id,reversal_of,completed_at)
        VALUES (p_reference,'REVERSAL','SUCCESS',v_orig.customer_id,p_txn,now()) RETURNING txn_id INTO v_new;
    UPDATE wallets SET balance = balance + v_ord.sell_amount WHERE wallet_id=v_ord.sell_wallet RETURNING balance INTO b1;
    UPDATE wallets SET balance = balance - v_ord.sell_amount WHERE wallet_id=v_hn            RETURNING balance INTO b2;
    UPDATE wallets SET balance = balance + v_ord.buy_amount  WHERE wallet_id=v_hb            RETURNING balance INTO b3;
    UPDATE wallets SET balance = balance - v_ord.buy_amount  WHERE wallet_id=v_ord.buy_wallet RETURNING balance INTO b4; -- CHECK blocks if customer already spent it
    INSERT INTO ledger_entries(txn_id,wallet_id,direction,amount,balance_after) VALUES
        (v_new, v_hn,             'DR', v_ord.sell_amount, b2),
        (v_new, v_ord.sell_wallet,'CR', v_ord.sell_amount, b1),
        (v_new, v_ord.buy_wallet, 'DR', v_ord.buy_amount,  b4),
        (v_new, v_hb,             'CR', v_ord.buy_amount,  b3);
    UPDATE transactions SET status='REVERSED' WHERE txn_id = p_txn;
    UPDATE fx_orders    SET status='CANCELLED' WHERE txn_id = p_txn;   -- frees the customer's daily limit
    RETURN v_new;
END $$;
