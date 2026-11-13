-- =====================================================================
-- MIT 8103 Advanced Database Systems | Portfolio 1: Database Design
-- Case study: NairaLink FX (SIMULATED cross-border FX & multi-currency
-- wallet platform, modelled on publicly visible features of Nigerian
-- fintech FX/investment apps). Engine: PostgreSQL 16.
-- =====================================================================
DROP SCHEMA IF EXISTS fx CASCADE;
CREATE SCHEMA fx;
SET search_path = fx, public;

-- ---------- Reference data -------------------------------------------
CREATE TABLE currencies (
    currency_code  CHAR(3)      PRIMARY KEY,               -- ISO 4217
    currency_name  VARCHAR(60)  NOT NULL,
    decimals       SMALLINT     NOT NULL DEFAULT 2 CHECK (decimals BETWEEN 0 AND 4),
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE kyc_tiers (
    tier             SMALLINT PRIMARY KEY CHECK (tier BETWEEN 0 AND 3),
    tier_name        VARCHAR(30)    NOT NULL,
    daily_limit_ngn  NUMERIC(18,2)  NOT NULL CHECK (daily_limit_ngn >= 0),
    fee_pct          NUMERIC(5,4)   NOT NULL CHECK (fee_pct BETWEEN 0 AND 0.05)
);

-- ---------- Customers & wallets --------------------------------------
CREATE TABLE customers (
    customer_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         VARCHAR(120) NOT NULL UNIQUE,
    phone         VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL,
    country_code  CHAR(2)      NOT NULL DEFAULT 'NG',
    kyc_tier      SMALLINT     NOT NULL DEFAULT 0 REFERENCES kyc_tiers(tier),
    status        VARCHAR(12)  NOT NULL DEFAULT 'ACTIVE'
                  CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_email_format CHECK (email LIKE '%_@_%.__%')
);

CREATE TABLE wallets (
    wallet_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id    BIGINT   NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    currency_code  CHAR(3)  NOT NULL REFERENCES currencies(currency_code),
    wallet_type    VARCHAR(10) NOT NULL DEFAULT 'CUSTOMER'
                   CHECK (wallet_type IN ('CUSTOMER','SETTLEMENT')),
    balance        NUMERIC(20,4) NOT NULL DEFAULT 0,
    held_amount    NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (held_amount >= 0),
    version        INT      NOT NULL DEFAULT 0,        -- optimistic-lock counter
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_wallet_per_currency UNIQUE (customer_id, currency_code),
    -- customers can never overdraw; SETTLEMENT (house/clearing) wallets are net positions and may be negative
    CONSTRAINT chk_no_overdraft       CHECK (wallet_type = 'SETTLEMENT' OR balance >= 0),
    CONSTRAINT chk_hold_le_balance    CHECK (held_amount = 0 OR held_amount <= balance)
);

-- ---------- Market data ----------------------------------------------
CREATE TABLE liquidity_providers (
    lp_id    SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lp_name  VARCHAR(60) NOT NULL UNIQUE,
    country  CHAR(2)     NOT NULL,
    is_active BOOLEAN    NOT NULL DEFAULT TRUE
);

CREATE TABLE fx_rates (                     -- append-only time series
    rate_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    base_ccy     CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    quote_ccy    CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    bid          NUMERIC(18,6) NOT NULL CHECK (bid > 0),
    ask          NUMERIC(18,6) NOT NULL,
    lp_id        SMALLINT NOT NULL REFERENCES liquidity_providers(lp_id),
    captured_at  TIMESTAMPTZ NOT NULL,
    CONSTRAINT chk_pair_distinct CHECK (base_ccy <> quote_ccy),
    CONSTRAINT chk_spread_valid  CHECK (ask >= bid)
);

-- ---------- Transactions, orders & double-entry ledger ---------------
CREATE TABLE transactions (
    txn_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference    VARCHAR(40) NOT NULL UNIQUE,            -- external / idempotency ref
    txn_type     VARCHAR(15) NOT NULL
                 CHECK (txn_type IN ('FUNDING','WITHDRAWAL','FX_CONVERSION','TRANSFER','FEE','REVERSAL')),
    status       VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                 CHECK (status IN ('PENDING','SUCCESS','FAILED','REVERSED')),
    customer_id  BIGINT NOT NULL REFERENCES customers(customer_id),
    reversal_of  BIGINT REFERENCES transactions(txn_id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    CONSTRAINT chk_reversal_self CHECK (reversal_of IS NULL OR reversal_of <> txn_id)
);

CREATE TABLE fx_orders (
    order_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id        BIGINT NOT NULL UNIQUE REFERENCES transactions(txn_id),
    customer_id   BIGINT NOT NULL REFERENCES customers(customer_id),
    sell_wallet   BIGINT NOT NULL REFERENCES wallets(wallet_id),
    buy_wallet    BIGINT NOT NULL REFERENCES wallets(wallet_id),
    order_type    VARCHAR(7) NOT NULL DEFAULT 'MARKET' CHECK (order_type IN ('MARKET','LIMIT')),
    sell_amount   NUMERIC(20,4) NOT NULL CHECK (sell_amount > 0),
    buy_amount    NUMERIC(20,4) NOT NULL CHECK (buy_amount  > 0),
    rate_applied  NUMERIC(18,6) NOT NULL CHECK (rate_applied > 0),
    fee_amount    NUMERIC(20,4) NOT NULL DEFAULT 0 CHECK (fee_amount >= 0),
    lp_id         SMALLINT REFERENCES liquidity_providers(lp_id),
    status        VARCHAR(10) NOT NULL DEFAULT 'FILLED'
                  CHECK (status IN ('OPEN','FILLED','CANCELLED','REJECTED')),
    placed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_distinct_wallets CHECK (sell_wallet <> buy_wallet)
);

CREATE TABLE ledger_entries (               -- immutable double-entry journal
    entry_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id        BIGINT NOT NULL REFERENCES transactions(txn_id),
    wallet_id     BIGINT NOT NULL REFERENCES wallets(wallet_id),
    direction     CHAR(2) NOT NULL CHECK (direction IN ('DR','CR')),
    amount        NUMERIC(20,4) NOT NULL CHECK (amount > 0),
    balance_after NUMERIC(20,4) NOT NULL,          -- running balance (may be <0 only for SETTLEMENT wallets)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE payments (                     -- bank / card rails for fund & withdraw
    payment_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id        BIGINT NOT NULL REFERENCES transactions(txn_id),
    channel       VARCHAR(15) NOT NULL CHECK (channel IN ('BANK_TRANSFER','CARD','USSD','SWIFT')),
    provider_ref  VARCHAR(60) NOT NULL UNIQUE,
    amount        NUMERIC(20,4) NOT NULL CHECK (amount > 0),
    currency_code CHAR(3) NOT NULL REFERENCES currencies(currency_code),
    status        VARCHAR(10) NOT NULL CHECK (status IN ('INITIATED','CONFIRMED','FAILED')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (                    -- populated by trigger (see 02_triggers.sql)
    audit_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name  TEXT NOT NULL,
    operation   CHAR(1) NOT NULL CHECK (operation IN ('I','U','D')),
    row_pk      TEXT NOT NULL,
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT NOT NULL DEFAULT current_user,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Reference-data seed (needed for FK integrity)
INSERT INTO currencies VALUES
 ('NGN','Nigerian Naira',2,true),('USD','US Dollar',2,true),('GBP','Pound Sterling',2,true),
 ('EUR','Euro',2,true),('CAD','Canadian Dollar',2,true),('GHS','Ghanaian Cedi',2,true),
 ('KES','Kenyan Shilling',2,true);
INSERT INTO kyc_tiers VALUES
 (0,'Unverified',        0,        0.0200),
 (1,'Basic (BVN+phone)', 500000,   0.0150),
 (2,'Standard (ID+selfie)', 5000000, 0.0100),
 (3,'Premium (address+SoF)', 50000000, 0.0050);
INSERT INTO liquidity_providers (lp_name,country) VALUES
 ('Atlas Bank Treasury','NG'),('Meridian FX Desk','GB'),('Lagos Interbank Window','NG');
