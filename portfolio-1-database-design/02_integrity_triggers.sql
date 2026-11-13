-- =====================================================================
-- Portfolio 1 (cont.): integrity rules that CHECK/FK cannot express.
-- 1) Generic audit trigger  2) Wallet version bump
-- 3) Deferred double-entry rule: per transaction & per currency,
--    total debits must equal total credits.
-- =====================================================================
SET search_path = fx, public;

-- 1) audit -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fx.fn_audit() RETURNS trigger LANGUAGE plpgsql AS $$
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

-- Only sensitive changes are audited (KYC tier / status of customers).
CREATE TRIGGER trg_audit_customers
AFTER UPDATE OF kyc_tier, status ON fx.customers
FOR EACH ROW EXECUTE FUNCTION fx.fn_audit('customer_id');

-- 2) optimistic-lock version bump --------------------------------------
CREATE OR REPLACE FUNCTION fx.fn_wallet_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.balance IS DISTINCT FROM OLD.balance THEN NEW.version := OLD.version + 1; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_wallet_version BEFORE UPDATE ON fx.wallets
FOR EACH ROW EXECUTE FUNCTION fx.fn_wallet_version();

-- 3) ledger immutability + double-entry balance -------------------------
CREATE OR REPLACE FUNCTION fx.fn_ledger_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ledger_entries is append-only (% blocked); post a REVERSAL instead', TG_OP;
END $$;
CREATE TRIGGER trg_ledger_no_update BEFORE UPDATE OR DELETE ON fx.ledger_entries
FOR EACH ROW EXECUTE FUNCTION fx.fn_ledger_immutable();

CREATE OR REPLACE FUNCTION fx.fn_ledger_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
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

-- DEFERRABLE INITIALLY DEFERRED => checked at COMMIT, after all legs are inserted
CREATE CONSTRAINT TRIGGER trg_ledger_balanced
AFTER INSERT ON fx.ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION fx.fn_ledger_balanced();
