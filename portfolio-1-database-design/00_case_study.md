# Selected Case Study: NairaLink FX (simulated fintech FX platform)

**Organisation / scenario.** *NairaLink FX* is a **simulated** Nigerian fintech that lets retail customers hold
multi-currency wallets (NGN, USD, GBP, EUR, CAD, GHS, KES), fund them from local bank rails, convert between
currencies at a quoted FX rate, and withdraw. It is modelled on the *publicly visible* product features of
Nigerian fintech FX/investment apps (e.g. Bamboo, Cowrywise). **Every data is synthetic.**

**Nature of the business.** Money-movement and FX conversion. The platform does not hold the market view; it
sources a price from **liquidity providers** (banks / FX desks), adds a **spread** and a KYC-tier-based
**fee**, and records every movement of value in an **immutable double-entry ledger**.

**Users of the database**
| User | Function |
|---|---|
| Retail customer (via app/API) | Fund wallet, view balances, convert currency, withdraw |
| Operations / support | Look up transactions, reverse failed ones |
| Compliance officer | Review KYC tiers, daily limits, audit trail |
| Treasury | Watch house float per currency, LP prices and fill volume |
| Finance / audit | Reconcile ledger totals vs wallet balances |

**Major data stored.** Customers & KYC tier, wallets per currency, FX rates (bid/ask time series per
liquidity provider), transactions (funding, withdrawal, FX conversion, transfer, fee, reversal), FX orders,
double-entry ledger entries, payment-rail records, audit log. Unstructured/semi-structured data (KYC
documents, device sessions, notification preferences, trade history snapshots, rate ticks) is modelled in
MongoDB in Portfolio 4.

**Key operations the database supports**
1. Open wallet / upgrade KYC tier (audited).
2. Fund wallet (bank transfer confirmed -> credit).
3. **Convert currency** at the live ask/bid with fee, atomically across 4 ledger legs.
4. Withdraw, and **reverse** failed/incorrect transactions without mutating history.
5. **Audit balances**: prove wallet balance = sum of ledger entries; every txn balances per currency.
6. Analytics: daily volume by pair, top customers, spread revenue, LP performance, near-limit customers.

## How an FX conversion works (the process the schema must support)
1. Customer asks to sell NGN to buy USD. The app reads the latest `fx_rates` ask for USD/NGN.
2. Platform computes `buy_amount = sell_amount / rate_applied` and `fee = sell_amount * tier fee_pct`.
3. In **one database transaction**: lock both customer wallets, check funds, update balances, insert
   `transactions` + `fx_orders` + four `ledger_entries` (customer<->house in each currency).
4. If anything fails (insufficient funds, stale rate, constraint) the whole thing **rolls back**.
5. Ops can later insert a `REVERSAL` transaction with opposite ledger legs; nothing is edited or deleted.

The **house account** (customer 1) owns a float wallet in every currency. Every customer movement has a
house counter-leg, so debits equal credits **per currency per transaction** (enforced by a deferred
constraint trigger) and the entire ledger always nets to zero.
