--
-- PostgreSQL database dump
--

\restrict DdqUcoz8xrPAyrRFfGIpSFhUcK8odNNBU8HX6Yl3KjSay2oKgEAUU2LjQRUaMfg

-- Dumped from database version 16.16 (Debian 16.16-1.pgdg13+1)
-- Dumped by pg_dump version 18.2

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fx; Type: SCHEMA; Schema: -; Owner: pguser
--

CREATE SCHEMA fx;


ALTER SCHEMA fx OWNER TO pguser;

--
-- Name: fn_audit(); Type: FUNCTION; Schema: fx; Owner: pguser
--

CREATE FUNCTION fx.fn_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE pk TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
     pk := to_jsonb(OLD) ->> TG_ARGV[0];
     INSERT INTO fx.audit_log(table_name, operation, row_pk, old_data)
     VALUES (TG_TABLE_NAME, 'D', pk, to_jsonb(OLD));
     RETURN OLD;
  ELSIF TG_OP = 'UPDATE' THEN
     pk := to_jsonb(NEW) ->> TG_ARGV[0];
     INSERT INTO fx.audit_log(table_name, operation, row_pk, old_data, new_data)
     VALUES (TG_TABLE_NAME, 'U', pk, to_jsonb(OLD), to_jsonb(NEW));
     RETURN NEW;
  ELSE
     pk := to_jsonb(NEW) ->> TG_ARGV[0];
     INSERT INTO fx.audit_log(table_name, operation, row_pk, new_data)
     VALUES (TG_TABLE_NAME, 'I', pk, to_jsonb(NEW));
     RETURN NEW;
  END IF;
END $$;


ALTER FUNCTION fx.fn_audit() OWNER TO pguser;

--
-- Name: fn_ledger_balanced(); Type: FUNCTION; Schema: fx; Owner: pguser
--

CREATE FUNCTION fx.fn_ledger_balanced() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE bad RECORD;
BEGIN
  SELECT w.currency_code, SUM(CASE le.direction WHEN 'DR' THEN le.amount ELSE -le.amount END) AS diff
    INTO bad
    FROM fx.ledger_entries le JOIN fx.wallets w USING (wallet_id)
   WHERE le.txn_id = NEW.txn_id
   GROUP BY w.currency_code
  HAVING SUM(CASE le.direction WHEN 'DR' THEN le.amount ELSE -le.amount END) <> 0
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Unbalanced ledger for txn % in %: DR-CR = %', NEW.txn_id, bad.currency_code, bad.diff;
  END IF;
  RETURN NULL;
END $$;


ALTER FUNCTION fx.fn_ledger_balanced() OWNER TO pguser;

--
-- Name: fn_ledger_immutable(); Type: FUNCTION; Schema: fx; Owner: pguser
--

CREATE FUNCTION fx.fn_ledger_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'ledger_entries is append-only (% blocked); post a REVERSAL instead', TG_OP;
END $$;


ALTER FUNCTION fx.fn_ledger_immutable() OWNER TO pguser;

--
-- Name: fn_wallet_version(); Type: FUNCTION; Schema: fx; Owner: pguser
--

CREATE FUNCTION fx.fn_wallet_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.balance IS DISTINCT FROM OLD.balance THEN NEW.version := OLD.version + 1; END IF;
  RETURN NEW;
END $$;


ALTER FUNCTION fx.fn_wallet_version() OWNER TO pguser;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit_log; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.audit_log (
    audit_id bigint NOT NULL,
    table_name text NOT NULL,
    operation character(1) NOT NULL,
    row_pk text NOT NULL,
    old_data jsonb,
    new_data jsonb,
    changed_by text DEFAULT CURRENT_USER NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_log_operation_check CHECK ((operation = ANY (ARRAY['I'::bpchar, 'U'::bpchar, 'D'::bpchar])))
);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN audit_id SET (pg_attver=36557968);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN table_name SET (pg_attver=36557968);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN operation SET (pg_attver=36557968);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN row_pk SET (pg_attver=36557968);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN old_data SET (pg_attver=36557968);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN new_data SET (pg_attver=36557968);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN changed_by SET (pg_attver=36557968);
ALTER TABLE ONLY fx.audit_log ALTER COLUMN changed_at SET (pg_attver=36557968);


ALTER TABLE fx.audit_log OWNER TO pguser;

--
-- Name: audit_log_audit_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.audit_log ALTER COLUMN audit_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.audit_log_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: currencies; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.currencies (
    currency_code character(3) NOT NULL,
    currency_name character varying(60) NOT NULL,
    decimals smallint DEFAULT 2 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT currencies_decimals_check CHECK (((decimals >= 0) AND (decimals <= 4)))
);
ALTER TABLE ONLY fx.currencies ALTER COLUMN currency_code SET (pg_attver=36244496);
ALTER TABLE ONLY fx.currencies ALTER COLUMN currency_name SET (pg_attver=36244496);
ALTER TABLE ONLY fx.currencies ALTER COLUMN decimals SET (pg_attver=36244496);
ALTER TABLE ONLY fx.currencies ALTER COLUMN is_active SET (pg_attver=36244496);


ALTER TABLE fx.currencies OWNER TO pguser;

--
-- Name: customers; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.customers (
    customer_id bigint NOT NULL,
    email character varying(120) NOT NULL,
    phone character varying(20) NOT NULL,
    full_name character varying(120) NOT NULL,
    country_code character(2) DEFAULT 'NG'::bpchar NOT NULL,
    kyc_tier smallint DEFAULT 0 NOT NULL,
    status character varying(12) DEFAULT 'ACTIVE'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_email_format CHECK (((email)::text ~~ '%_@_%.__%'::text)),
    CONSTRAINT customers_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'SUSPENDED'::character varying, 'CLOSED'::character varying])::text[])))
);
ALTER TABLE ONLY fx.customers ALTER COLUMN customer_id SET (pg_attver=36278144);
ALTER TABLE ONLY fx.customers ALTER COLUMN email SET (pg_attver=36278144);
ALTER TABLE ONLY fx.customers ALTER COLUMN phone SET (pg_attver=36278144);
ALTER TABLE ONLY fx.customers ALTER COLUMN full_name SET (pg_attver=36278144);
ALTER TABLE ONLY fx.customers ALTER COLUMN country_code SET (pg_attver=36278144);
ALTER TABLE ONLY fx.customers ALTER COLUMN kyc_tier SET (pg_attver=36278144);
ALTER TABLE ONLY fx.customers ALTER COLUMN status SET (pg_attver=36278144);
ALTER TABLE ONLY fx.customers ALTER COLUMN created_at SET (pg_attver=36278144);


ALTER TABLE fx.customers OWNER TO pguser;

--
-- Name: customers_customer_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.customers ALTER COLUMN customer_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.customers_customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fx_orders; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.fx_orders (
    order_id bigint NOT NULL,
    txn_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    sell_wallet bigint NOT NULL,
    buy_wallet bigint NOT NULL,
    order_type character varying(7) DEFAULT 'MARKET'::character varying NOT NULL,
    sell_amount numeric(20,4) NOT NULL,
    buy_amount numeric(20,4) NOT NULL,
    rate_applied numeric(18,6) NOT NULL,
    fee_amount numeric(20,4) DEFAULT 0 NOT NULL,
    lp_id smallint,
    status character varying(10) DEFAULT 'FILLED'::character varying NOT NULL,
    placed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_distinct_wallets CHECK ((sell_wallet <> buy_wallet)),
    CONSTRAINT fx_orders_buy_amount_check CHECK ((buy_amount > (0)::numeric)),
    CONSTRAINT fx_orders_fee_amount_check CHECK ((fee_amount >= (0)::numeric)),
    CONSTRAINT fx_orders_order_type_check CHECK (((order_type)::text = ANY ((ARRAY['MARKET'::character varying, 'LIMIT'::character varying])::text[]))),
    CONSTRAINT fx_orders_rate_applied_check CHECK ((rate_applied > (0)::numeric)),
    CONSTRAINT fx_orders_sell_amount_check CHECK ((sell_amount > (0)::numeric)),
    CONSTRAINT fx_orders_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'FILLED'::character varying, 'CANCELLED'::character varying, 'REJECTED'::character varying])::text[])))
);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN order_id SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN txn_id SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN customer_id SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN sell_wallet SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN buy_wallet SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN order_type SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN sell_amount SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN buy_amount SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN rate_applied SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN fee_amount SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN lp_id SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN status SET (pg_attver=36438176);
ALTER TABLE ONLY fx.fx_orders ALTER COLUMN placed_at SET (pg_attver=36438176);


ALTER TABLE fx.fx_orders OWNER TO pguser;

--
-- Name: fx_orders_order_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.fx_orders ALTER COLUMN order_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.fx_orders_order_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fx_rates; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.fx_rates (
    rate_id bigint NOT NULL,
    base_ccy character(3) NOT NULL,
    quote_ccy character(3) NOT NULL,
    bid numeric(18,6) NOT NULL,
    ask numeric(18,6) NOT NULL,
    lp_id smallint NOT NULL,
    captured_at timestamp with time zone NOT NULL,
    CONSTRAINT chk_pair_distinct CHECK ((base_ccy <> quote_ccy)),
    CONSTRAINT chk_spread_valid CHECK ((ask >= bid)),
    CONSTRAINT fx_rates_bid_check CHECK ((bid > (0)::numeric))
);
ALTER TABLE ONLY fx.fx_rates ALTER COLUMN rate_id SET (pg_attver=36372168);
ALTER TABLE ONLY fx.fx_rates ALTER COLUMN base_ccy SET (pg_attver=36372168);
ALTER TABLE ONLY fx.fx_rates ALTER COLUMN quote_ccy SET (pg_attver=36372168);
ALTER TABLE ONLY fx.fx_rates ALTER COLUMN bid SET (pg_attver=36372168);
ALTER TABLE ONLY fx.fx_rates ALTER COLUMN ask SET (pg_attver=36372168);
ALTER TABLE ONLY fx.fx_rates ALTER COLUMN lp_id SET (pg_attver=36372168);
ALTER TABLE ONLY fx.fx_rates ALTER COLUMN captured_at SET (pg_attver=36372168);


ALTER TABLE fx.fx_rates OWNER TO pguser;

--
-- Name: fx_rates_rate_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.fx_rates ALTER COLUMN rate_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.fx_rates_rate_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: kyc_tiers; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.kyc_tiers (
    tier smallint NOT NULL,
    tier_name character varying(30) NOT NULL,
    daily_limit_ngn numeric(18,2) NOT NULL,
    fee_pct numeric(5,4) NOT NULL,
    CONSTRAINT kyc_tiers_daily_limit_ngn_check CHECK ((daily_limit_ngn >= (0)::numeric)),
    CONSTRAINT kyc_tiers_fee_pct_check CHECK (((fee_pct >= (0)::numeric) AND (fee_pct <= 0.05))),
    CONSTRAINT kyc_tiers_tier_check CHECK (((tier >= 0) AND (tier <= 3)))
);
ALTER TABLE ONLY fx.kyc_tiers ALTER COLUMN tier SET (pg_attver=36256608);
ALTER TABLE ONLY fx.kyc_tiers ALTER COLUMN tier_name SET (pg_attver=36256608);
ALTER TABLE ONLY fx.kyc_tiers ALTER COLUMN daily_limit_ngn SET (pg_attver=36256608);
ALTER TABLE ONLY fx.kyc_tiers ALTER COLUMN fee_pct SET (pg_attver=36256608);


ALTER TABLE fx.kyc_tiers OWNER TO pguser;

--
-- Name: ledger_entries; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.ledger_entries (
    entry_id bigint NOT NULL,
    txn_id bigint NOT NULL,
    wallet_id bigint NOT NULL,
    direction character(2) NOT NULL,
    amount numeric(20,4) NOT NULL,
    balance_after numeric(20,4) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ledger_entries_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT ledger_entries_direction_check CHECK ((direction = ANY (ARRAY['DR'::bpchar, 'CR'::bpchar])))
);
ALTER TABLE ONLY fx.ledger_entries ALTER COLUMN entry_id SET (pg_attver=36498664);
ALTER TABLE ONLY fx.ledger_entries ALTER COLUMN txn_id SET (pg_attver=36498664);
ALTER TABLE ONLY fx.ledger_entries ALTER COLUMN wallet_id SET (pg_attver=36498664);
ALTER TABLE ONLY fx.ledger_entries ALTER COLUMN direction SET (pg_attver=36498664);
ALTER TABLE ONLY fx.ledger_entries ALTER COLUMN amount SET (pg_attver=36498664);
ALTER TABLE ONLY fx.ledger_entries ALTER COLUMN balance_after SET (pg_attver=36498664);
ALTER TABLE ONLY fx.ledger_entries ALTER COLUMN created_at SET (pg_attver=36498664);


ALTER TABLE fx.ledger_entries OWNER TO pguser;

--
-- Name: ledger_entries_entry_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.ledger_entries ALTER COLUMN entry_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.ledger_entries_entry_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: liquidity_providers; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.liquidity_providers (
    lp_id smallint NOT NULL,
    lp_name character varying(60) NOT NULL,
    country character(2) NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);
ALTER TABLE ONLY fx.liquidity_providers ALTER COLUMN lp_id SET (pg_attver=36356120);
ALTER TABLE ONLY fx.liquidity_providers ALTER COLUMN lp_name SET (pg_attver=36356120);
ALTER TABLE ONLY fx.liquidity_providers ALTER COLUMN country SET (pg_attver=36356120);
ALTER TABLE ONLY fx.liquidity_providers ALTER COLUMN is_active SET (pg_attver=36356120);


ALTER TABLE fx.liquidity_providers OWNER TO pguser;

--
-- Name: liquidity_providers_lp_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.liquidity_providers ALTER COLUMN lp_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.liquidity_providers_lp_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payments; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.payments (
    payment_id bigint NOT NULL,
    txn_id bigint NOT NULL,
    channel character varying(15) NOT NULL,
    provider_ref character varying(60) NOT NULL,
    amount numeric(20,4) NOT NULL,
    currency_code character(3) NOT NULL,
    status character varying(10) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payments_channel_check CHECK (((channel)::text = ANY ((ARRAY['BANK_TRANSFER'::character varying, 'CARD'::character varying, 'USSD'::character varying, 'SWIFT'::character varying])::text[]))),
    CONSTRAINT payments_status_check CHECK (((status)::text = ANY ((ARRAY['INITIATED'::character varying, 'CONFIRMED'::character varying, 'FAILED'::character varying])::text[])))
);
ALTER TABLE ONLY fx.payments ALTER COLUMN payment_id SET (pg_attver=36525720);
ALTER TABLE ONLY fx.payments ALTER COLUMN txn_id SET (pg_attver=36525720);
ALTER TABLE ONLY fx.payments ALTER COLUMN channel SET (pg_attver=36525720);
ALTER TABLE ONLY fx.payments ALTER COLUMN provider_ref SET (pg_attver=36525720);
ALTER TABLE ONLY fx.payments ALTER COLUMN amount SET (pg_attver=36525720);
ALTER TABLE ONLY fx.payments ALTER COLUMN currency_code SET (pg_attver=36525720);
ALTER TABLE ONLY fx.payments ALTER COLUMN status SET (pg_attver=36525720);
ALTER TABLE ONLY fx.payments ALTER COLUMN created_at SET (pg_attver=36525720);


ALTER TABLE fx.payments OWNER TO pguser;

--
-- Name: payments_payment_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.payments ALTER COLUMN payment_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.payments_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: transactions; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.transactions (
    txn_id bigint NOT NULL,
    reference character varying(40) NOT NULL,
    txn_type character varying(15) NOT NULL,
    status character varying(10) DEFAULT 'PENDING'::character varying NOT NULL,
    customer_id bigint NOT NULL,
    reversal_of bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT chk_reversal_self CHECK (((reversal_of IS NULL) OR (reversal_of <> txn_id))),
    CONSTRAINT transactions_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'SUCCESS'::character varying, 'FAILED'::character varying, 'REVERSED'::character varying])::text[]))),
    CONSTRAINT transactions_txn_type_check CHECK (((txn_type)::text = ANY ((ARRAY['FUNDING'::character varying, 'WITHDRAWAL'::character varying, 'FX_CONVERSION'::character varying, 'TRANSFER'::character varying, 'FEE'::character varying, 'REVERSAL'::character varying])::text[])))
);
ALTER TABLE ONLY fx.transactions ALTER COLUMN txn_id SET (pg_attver=36403776);
ALTER TABLE ONLY fx.transactions ALTER COLUMN reference SET (pg_attver=36403776);
ALTER TABLE ONLY fx.transactions ALTER COLUMN txn_type SET (pg_attver=36403776);
ALTER TABLE ONLY fx.transactions ALTER COLUMN status SET (pg_attver=36403776);
ALTER TABLE ONLY fx.transactions ALTER COLUMN customer_id SET (pg_attver=36403776);
ALTER TABLE ONLY fx.transactions ALTER COLUMN reversal_of SET (pg_attver=36403776);
ALTER TABLE ONLY fx.transactions ALTER COLUMN created_at SET (pg_attver=36403776);
ALTER TABLE ONLY fx.transactions ALTER COLUMN completed_at SET (pg_attver=36403776);


ALTER TABLE fx.transactions OWNER TO pguser;

--
-- Name: transactions_txn_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.transactions ALTER COLUMN txn_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.transactions_txn_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: wallets; Type: TABLE; Schema: fx; Owner: pguser
--

CREATE TABLE fx.wallets (
    wallet_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    currency_code character(3) NOT NULL,
    wallet_type character varying(10) DEFAULT 'CUSTOMER'::character varying NOT NULL,
    balance numeric(20,4) DEFAULT 0 NOT NULL,
    held_amount numeric(20,4) DEFAULT 0 NOT NULL,
    version integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_hold_le_balance CHECK (((held_amount = (0)::numeric) OR (held_amount <= balance))),
    CONSTRAINT chk_no_overdraft CHECK ((((wallet_type)::text = 'SETTLEMENT'::text) OR (balance >= (0)::numeric))),
    CONSTRAINT wallets_held_amount_check CHECK ((held_amount >= (0)::numeric)),
    CONSTRAINT wallets_wallet_type_check CHECK (((wallet_type)::text = ANY ((ARRAY['CUSTOMER'::character varying, 'SETTLEMENT'::character varying])::text[])))
);
ALTER TABLE ONLY fx.wallets ALTER COLUMN wallet_id SET (pg_attver=36311696);
ALTER TABLE ONLY fx.wallets ALTER COLUMN customer_id SET (pg_attver=36311696);
ALTER TABLE ONLY fx.wallets ALTER COLUMN currency_code SET (pg_attver=36311696);
ALTER TABLE ONLY fx.wallets ALTER COLUMN wallet_type SET (pg_attver=36311696);
ALTER TABLE ONLY fx.wallets ALTER COLUMN balance SET (pg_attver=36311696);
ALTER TABLE ONLY fx.wallets ALTER COLUMN held_amount SET (pg_attver=36311696);
ALTER TABLE ONLY fx.wallets ALTER COLUMN version SET (pg_attver=36311696);
ALTER TABLE ONLY fx.wallets ALTER COLUMN created_at SET (pg_attver=36311696);


ALTER TABLE fx.wallets OWNER TO pguser;

--
-- Name: wallets_wallet_id_seq; Type: SEQUENCE; Schema: fx; Owner: pguser
--

ALTER TABLE fx.wallets ALTER COLUMN wallet_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME fx.wallets_wallet_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (audit_id);


--
-- Name: currencies currencies_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.currencies
    ADD CONSTRAINT currencies_pkey PRIMARY KEY (currency_code);


--
-- Name: customers customers_email_key; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.customers
    ADD CONSTRAINT customers_email_key UNIQUE (email);


--
-- Name: customers customers_phone_key; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.customers
    ADD CONSTRAINT customers_phone_key UNIQUE (phone);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- Name: fx_orders fx_orders_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_orders
    ADD CONSTRAINT fx_orders_pkey PRIMARY KEY (order_id);


--
-- Name: fx_orders fx_orders_txn_id_key; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_orders
    ADD CONSTRAINT fx_orders_txn_id_key UNIQUE (txn_id);


--
-- Name: fx_rates fx_rates_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_rates
    ADD CONSTRAINT fx_rates_pkey PRIMARY KEY (rate_id);


--
-- Name: kyc_tiers kyc_tiers_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.kyc_tiers
    ADD CONSTRAINT kyc_tiers_pkey PRIMARY KEY (tier);


--
-- Name: ledger_entries ledger_entries_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.ledger_entries
    ADD CONSTRAINT ledger_entries_pkey PRIMARY KEY (entry_id);


--
-- Name: liquidity_providers liquidity_providers_lp_name_key; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.liquidity_providers
    ADD CONSTRAINT liquidity_providers_lp_name_key UNIQUE (lp_name);


--
-- Name: liquidity_providers liquidity_providers_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.liquidity_providers
    ADD CONSTRAINT liquidity_providers_pkey PRIMARY KEY (lp_id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (payment_id);


--
-- Name: payments payments_provider_ref_key; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.payments
    ADD CONSTRAINT payments_provider_ref_key UNIQUE (provider_ref);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (txn_id);


--
-- Name: transactions transactions_reference_key; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.transactions
    ADD CONSTRAINT transactions_reference_key UNIQUE (reference);


--
-- Name: wallets uq_wallet_per_currency; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.wallets
    ADD CONSTRAINT uq_wallet_per_currency UNIQUE (customer_id, currency_code);


--
-- Name: wallets wallets_pkey; Type: CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.wallets
    ADD CONSTRAINT wallets_pkey PRIMARY KEY (wallet_id);


--
-- Name: customers trg_audit_customers; Type: TRIGGER; Schema: fx; Owner: pguser
--

CREATE TRIGGER trg_audit_customers AFTER UPDATE OF kyc_tier, status ON fx.customers FOR EACH ROW EXECUTE FUNCTION fx.fn_audit('customer_id');


--
-- Name: ledger_entries trg_ledger_balanced; Type: TRIGGER; Schema: fx; Owner: pguser
--

CREATE CONSTRAINT TRIGGER trg_ledger_balanced AFTER INSERT ON fx.ledger_entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fx.fn_ledger_balanced();


--
-- Name: ledger_entries trg_ledger_no_update; Type: TRIGGER; Schema: fx; Owner: pguser
--

CREATE TRIGGER trg_ledger_no_update BEFORE DELETE OR UPDATE ON fx.ledger_entries FOR EACH ROW EXECUTE FUNCTION fx.fn_ledger_immutable();


--
-- Name: wallets trg_wallet_version; Type: TRIGGER; Schema: fx; Owner: pguser
--

CREATE TRIGGER trg_wallet_version BEFORE UPDATE ON fx.wallets FOR EACH ROW EXECUTE FUNCTION fx.fn_wallet_version();


--
-- Name: customers customers_kyc_tier_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.customers
    ADD CONSTRAINT customers_kyc_tier_fkey FOREIGN KEY (kyc_tier) REFERENCES fx.kyc_tiers(tier);


--
-- Name: fx_orders fx_orders_buy_wallet_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_orders
    ADD CONSTRAINT fx_orders_buy_wallet_fkey FOREIGN KEY (buy_wallet) REFERENCES fx.wallets(wallet_id);


--
-- Name: fx_orders fx_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_orders
    ADD CONSTRAINT fx_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES fx.customers(customer_id);


--
-- Name: fx_orders fx_orders_lp_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_orders
    ADD CONSTRAINT fx_orders_lp_id_fkey FOREIGN KEY (lp_id) REFERENCES fx.liquidity_providers(lp_id);


--
-- Name: fx_orders fx_orders_sell_wallet_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_orders
    ADD CONSTRAINT fx_orders_sell_wallet_fkey FOREIGN KEY (sell_wallet) REFERENCES fx.wallets(wallet_id);


--
-- Name: fx_orders fx_orders_txn_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_orders
    ADD CONSTRAINT fx_orders_txn_id_fkey FOREIGN KEY (txn_id) REFERENCES fx.transactions(txn_id);


--
-- Name: fx_rates fx_rates_base_ccy_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_rates
    ADD CONSTRAINT fx_rates_base_ccy_fkey FOREIGN KEY (base_ccy) REFERENCES fx.currencies(currency_code);


--
-- Name: fx_rates fx_rates_lp_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_rates
    ADD CONSTRAINT fx_rates_lp_id_fkey FOREIGN KEY (lp_id) REFERENCES fx.liquidity_providers(lp_id);


--
-- Name: fx_rates fx_rates_quote_ccy_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.fx_rates
    ADD CONSTRAINT fx_rates_quote_ccy_fkey FOREIGN KEY (quote_ccy) REFERENCES fx.currencies(currency_code);


--
-- Name: ledger_entries ledger_entries_txn_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.ledger_entries
    ADD CONSTRAINT ledger_entries_txn_id_fkey FOREIGN KEY (txn_id) REFERENCES fx.transactions(txn_id);


--
-- Name: ledger_entries ledger_entries_wallet_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.ledger_entries
    ADD CONSTRAINT ledger_entries_wallet_id_fkey FOREIGN KEY (wallet_id) REFERENCES fx.wallets(wallet_id);


--
-- Name: payments payments_currency_code_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.payments
    ADD CONSTRAINT payments_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES fx.currencies(currency_code);


--
-- Name: payments payments_txn_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.payments
    ADD CONSTRAINT payments_txn_id_fkey FOREIGN KEY (txn_id) REFERENCES fx.transactions(txn_id);


--
-- Name: transactions transactions_customer_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.transactions
    ADD CONSTRAINT transactions_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES fx.customers(customer_id);


--
-- Name: transactions transactions_reversal_of_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.transactions
    ADD CONSTRAINT transactions_reversal_of_fkey FOREIGN KEY (reversal_of) REFERENCES fx.transactions(txn_id);


--
-- Name: wallets wallets_currency_code_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.wallets
    ADD CONSTRAINT wallets_currency_code_fkey FOREIGN KEY (currency_code) REFERENCES fx.currencies(currency_code);


--
-- Name: wallets wallets_customer_id_fkey; Type: FK CONSTRAINT; Schema: fx; Owner: pguser
--

ALTER TABLE ONLY fx.wallets
    ADD CONSTRAINT wallets_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES fx.customers(customer_id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--

\unrestrict DdqUcoz8xrPAyrRFfGIpSFhUcK8odNNBU8HX6Yl3KjSay2oKgEAUU2LjQRUaMfg

