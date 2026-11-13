# Normalisation walkthrough (UNF -> 1NF -> 2NF -> 3NF)

Starting point: how a spreadsheet-style "FX statement" a junior analyst might build looks.

## Unnormalised (UNF)
`FX_STATEMENT(order_id, txn_ref, cust_email, cust_name, cust_phone, kyc_tier, tier_name, daily_limit,
fee_pct, {wallets: ccy, balance}, sell_ccy, buy_ccy, sell_amt, buy_amt, rate, lp_name, lp_country, lp_id,
{ledger_lines: wallet, DR/CR, amt})`

Problems: repeating groups (wallets, ledger lines), customer & LP data repeated per order, tier attributes
repeated per customer.

## 1NF - atomic values, no repeating groups
Remove `{wallets}` and `{ledger_lines}` into their own rows. Key of the order row = `order_id`.
Wallets become rows keyed `(customer, currency)`; ledger lines keyed `(txn, line)`.

## 2NF - no partial dependency on part of a composite key
In `WALLET(customer_id, currency_code, cust_name, cust_email, currency_name, balance)` the key is
`(customer_id, currency_code)` but `cust_name, cust_email` depend only on `customer_id` and `currency_name`
only on `currency_code`. Split into `customers`, `currencies`, `wallets(customer_id, currency_code, balance)`.
(Implementation note: I use surrogate `wallet_id` and a `UNIQUE(customer_id,currency_code)` - equivalent
result.)

## 3NF - no transitive dependency on a non-key attribute
`customers(customer_id, kyc_tier, tier_name, daily_limit, fee_pct)` has
`customer_id -> kyc_tier -> tier_name, daily_limit, fee_pct`. The tier attributes depend on `kyc_tier`, not on
the customer, so they move to `kyc_tiers`. Likewise `fx_orders(..., lp_id, lp_name, lp_country)` ->
`liquidity_providers`. `fx_rates` stores only `lp_id`.

## Final relations (all in 3NF / BCNF)
`currencies, kyc_tiers, customers, wallets, liquidity_providers, fx_rates, transactions, fx_orders,
ledger_entries, payments, audit_log` - see `01_schema.sql` and `erd.png`.
Every non-key attribute depends on "the key, the whole key, and nothing but the key".

## Deliberate, documented denormalisation (and why)
| Item | Why kept |
|---|---|
| `ledger_entries.balance_after` | Point-in-time audit; recomputing from history for every statement is expensive. Immutable, so it cannot go stale. |
| `fx_orders.rate_applied`, `fee_amount`, `buy_amount` | **Must** freeze the price the customer saw; recomputing from `fx_rates` later would give a different (wrong) answer. This is a historical fact, not a derivable value. |
| `wallets.balance` (derivable from ledger) | Hot-path read; kept consistent by the transactional posting procedure and verified by a reconciliation query (Portfolio 2/3). |

## Keys and constraints summary
* **PKs**: surrogate `BIGINT GENERATED ALWAYS AS IDENTITY` (reference tables use natural keys: ISO currency code, tier no.).
* **Candidate/unique keys**: `customers.email`, `customers.phone`, `transactions.reference` (idempotency),
  `payments.provider_ref`, `wallets(customer_id,currency_code)`, `fx_orders.txn_id` (1:1 with transaction).
* **FKs**: all relationships enforced; `ON DELETE RESTRICT` on wallets so financial history can never be orphaned.
* **CHECKs**: no overdraft on CUSTOMER wallets (`chk_no_overdraft`; SETTLEMENT wallets are net clearing positions and may be negative), `held_amount <= balance`, `ask >= bid`, `base <> quote`,
  positive amounts, enumerated status/type columns.
* **Triggers**: audit of KYC/status changes, wallet version bump (optimistic locking), append-only ledger,
  deferred per-currency double-entry balance check.
