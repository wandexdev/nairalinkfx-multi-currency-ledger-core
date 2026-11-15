-- =====================================================================
-- Portfolio 5: data distribution on the NairaLink FX PostgreSQL primary
--  A) Declarative RANGE partitioning of the 1.44M-row fx_rates time series (pruning + instant retention)
--  B) Horizontal sharding of wallets: HASH(customer_id) over two shard databases using postgres_fdw
-- Run: psql -d nairalink -f 03_partitioning_and_sharding.sql   (needs the FX schema + seed data)
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
SET search_path = fx, public;

\echo '########## A. RANGE PARTITIONING of fx_rates by month ##########'
SELECT min(captured_at)::date AS first_tick, max(captured_at)::date AS last_tick, count(*) FROM fx_rates;
DROP TABLE IF EXISTS fx_rates_p CASCADE;
CREATE TABLE fx_rates_p (LIKE fx_rates INCLUDING DEFAULTS INCLUDING CONSTRAINTS) PARTITION BY RANGE (captured_at);
ALTER TABLE fx_rates_p ADD PRIMARY KEY (rate_id, captured_at);        -- PK must contain the partition key
DO $$
DECLARE m date; mx date;
BEGIN
  SELECT date_trunc('month', min(captured_at))::date, date_trunc('month', max(captured_at))::date INTO m, mx FROM fx_rates;
  WHILE m <= mx LOOP
    EXECUTE format('CREATE TABLE fx_rates_p_%s PARTITION OF fx_rates_p FOR VALUES FROM (%L) TO (%L)', to_char(m,'YYYY_MM'), m, (m + interval '1 month')::date);
    m := (m + interval '1 month')::date;
  END LOOP;
END $$;
CREATE INDEX idx_fx_rates_p_pair_time ON fx_rates_p (base_ccy, quote_ccy, lp_id, captured_at DESC);   -- created on every partition
\timing on
INSERT INTO fx_rates_p SELECT * FROM fx_rates;
\timing off
ANALYZE fx_rates_p;
\echo '--- rows per partition'
SELECT c.relname AS partition, pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       to_char(pg_stat_get_live_tuples(c.oid),'999,999,999') AS rows
  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = 'fx_rates_p'::regclass ORDER BY 1;

\echo '--- same query, NON-partitioned table (index scan over the whole 1.44M-row index)'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT date_trunc('day', captured_at) d, avg((bid+ask)/2) FROM fx_rates
 WHERE base_ccy='USD' AND quote_ccy='NGN' AND lp_id=1 AND captured_at >= now() - interval '10 days' GROUP BY 1;
\echo '--- same query, PARTITIONED table: only the partitions overlapping the last 10 days are touched (partition pruning)'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT date_trunc('day', captured_at) d, avg((bid+ask)/2) FROM fx_rates_p
 WHERE base_ccy='USD' AND quote_ccy='NGN' AND lp_id=1 AND captured_at >= now() - interval '10 days' GROUP BY 1;

\echo '--- RETENTION: remove the oldest month. DELETE on the plain table (rolled back, just timing) vs DETACH PARTITION'
\timing on
BEGIN; DELETE FROM fx_rates WHERE captured_at < (SELECT min(captured_at) + interval '30 days' FROM fx_rates); ROLLBACK;
SELECT 'oldest partition' AS what, relname FROM pg_class WHERE relname = (SELECT min(c.relname) FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='fx_rates_p'::regclass) \gset
ALTER TABLE fx_rates_p DETACH PARTITION fx.:relname;
\timing off
\echo '(DETACH is a metadata change: no rows are rewritten. Re-attaching the partition to leave data intact:)'
SELECT to_char(date_trunc('month', min(captured_at)),'YYYY-MM-DD') AS lo, to_char(date_trunc('month', min(captured_at)) + interval '1 month','YYYY-MM-DD') AS hi FROM fx.:relname \gset
ALTER TABLE fx_rates_p ATTACH PARTITION fx.:relname FOR VALUES FROM (:'lo') TO (:'hi');
SELECT count(*) AS rows_in_partitioned_table_after_reattach FROM fx_rates_p;

\echo ''
\echo '########## B. SHARDING wallets: HASH(customer_id) across two shard databases via postgres_fdw ##########'
\c postgres
DROP DATABASE IF EXISTS nl_shard1; DROP DATABASE IF EXISTS nl_shard2; CREATE DATABASE nl_shard1; CREATE DATABASE nl_shard2;
\c nl_shard1
CREATE TABLE wallets_shard (wallet_id bigint PRIMARY KEY, customer_id bigint NOT NULL, currency_code char(3) NOT NULL, wallet_type text NOT NULL, balance numeric(20,4) NOT NULL);
CREATE INDEX ON wallets_shard(customer_id);
\c nl_shard2
CREATE TABLE wallets_shard (wallet_id bigint PRIMARY KEY, customer_id bigint NOT NULL, currency_code char(3) NOT NULL, wallet_type text NOT NULL, balance numeric(20,4) NOT NULL);
CREATE INDEX ON wallets_shard(customer_id);
\c nairalink
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SCHEMA IF EXISTS dist CASCADE; CREATE SCHEMA dist;
DROP SERVER IF EXISTS shard1 CASCADE; DROP SERVER IF EXISTS shard2 CASCADE;
CREATE SERVER shard1 FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'localhost', port '5432', dbname 'nl_shard1', batch_size '1000');
CREATE SERVER shard2 FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'localhost', port '5432', dbname 'nl_shard2', batch_size '1000');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard1 OPTIONS (user 'pguser');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard2 OPTIONS (user 'pguser');
CREATE TABLE dist.wallets (wallet_id bigint NOT NULL, customer_id bigint NOT NULL, currency_code char(3) NOT NULL, wallet_type text NOT NULL, balance numeric(20,4) NOT NULL) PARTITION BY HASH (customer_id);
CREATE FOREIGN TABLE dist.wallets_s1 PARTITION OF dist.wallets FOR VALUES WITH (MODULUS 2, REMAINDER 0) SERVER shard1 OPTIONS (schema_name 'public', table_name 'wallets_shard');
CREATE FOREIGN TABLE dist.wallets_s2 PARTITION OF dist.wallets FOR VALUES WITH (MODULUS 2, REMAINDER 1) SERVER shard2 OPTIONS (schema_name 'public', table_name 'wallets_shard');
\timing on
INSERT INTO dist.wallets SELECT wallet_id, customer_id, currency_code, wallet_type, balance FROM fx.wallets;   -- rows are routed to shards by hash(customer_id)
\timing off
\echo '--- distribution of the 80,007 wallets across shards'
SELECT tableoid::regclass AS shard_partition, count(*) AS wallets, count(DISTINCT customer_id) AS customers FROM dist.wallets GROUP BY 1 ORDER BY 1;
\echo '--- point lookup by shard key: ONLY ONE shard is contacted (partition pruning)'
EXPLAIN (VERBOSE, COSTS OFF) SELECT wallet_id, currency_code, balance FROM dist.wallets WHERE customer_id = 777;
SELECT wallet_id, currency_code, balance FROM dist.wallets WHERE customer_id = 777 ORDER BY wallet_id;
\echo '--- lookup WITHOUT the shard key (by wallet_id): must ask EVERY shard (scatter-gather)'
EXPLAIN (COSTS OFF) SELECT * FROM dist.wallets WHERE wallet_id = 3108;
SET enable_partitionwise_aggregate = on;
\echo '--- cross-shard aggregate, GROUP BY a NON-shard column (currency): PostgreSQL 16 cannot push this aggregate down;'
\echo '--- every shard ships its raw rows to the coordinator, which aggregates (cost grows with data volume)'
EXPLAIN (VERBOSE, COSTS OFF) SELECT currency_code, sum(balance) FROM dist.wallets WHERE wallet_type='CUSTOMER' GROUP BY currency_code;
\echo '--- GROUP BY the SHARD KEY (customer_id): each customer lives on one shard, so the aggregate IS pushed down (Remote SQL contains sum/GROUP BY)'
EXPLAIN (VERBOSE, COSTS OFF) SELECT customer_id, sum(balance) FROM dist.wallets WHERE wallet_type='CUSTOMER' AND currency_code='NGN' GROUP BY customer_id;
\echo '--- correctness: sharded totals == original totals'
SELECT 'sharded' AS src, currency_code, sum(balance) FROM dist.wallets WHERE wallet_type='CUSTOMER' GROUP BY 2
UNION ALL SELECT 'original', currency_code, sum(balance) FROM fx.wallets WHERE wallet_type='CUSTOMER' GROUP BY 2 ORDER BY 2, 1;
SELECT (SELECT sum(balance) FROM dist.wallets) = (SELECT sum(balance) FROM fx.wallets) AS totals_identical;
