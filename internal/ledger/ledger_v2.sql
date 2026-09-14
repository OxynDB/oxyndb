-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- VectoraDB Blackbox 2.0 — additive objects, installed AFTER ledger.sql.
--
-- Nothing here changes an object ledger.sql owns: vdb.schema_ledger, its hash
-- chain (_ledger_hash / chain_row) and its event triggers are untouched, so every
-- existing chain keeps verifying. 2.0 data lives in side tables keyed by the
-- ledger row id.
--
-- Safety rules for everything in this file:
--   * Fail-safe: a 2.0 trigger never aborts the statement that fired it. Errors
--     are downgraded to a WARNING and the original change goes through.
--   * Kill switch: ALTER DATABASE vectoradb SET vdb.v2 = 'off' makes every 2.0
--     trigger return immediately (new sessions).
--   * Idempotent: safe to re-apply on every start.
--
-- The install runs with session_replication_role = replica so the ledger's own
-- event triggers don't record this plumbing (that setting is session-local and
-- only a superuser can set it).

SET session_replication_role = replica;

-- ── Capture: extra context for every ledger row ─────────────────────────────
-- xid/lsn pin the exact moment of the change (Phase 4 branches from just before
-- it); task/parent_session/call_hash carry agent provenance (Phase 6);
-- override_used records that the destructive-DDL override was in effect.
CREATE TABLE IF NOT EXISTS vdb.ledger_ext (
  ledger_id      bigint PRIMARY KEY,   -- vdb.schema_ledger.id
  xid            bigint,               -- top-level transaction of the change
  lsn            pg_lsn,               -- WAL insert position when it was recorded
  task_id        text,                 -- vdb.task
  parent_session text,                 -- vdb.parent_session
  call_hash      text,                 -- vdb.call_hash (sha256 of an agent tool call)
  override_used  boolean NOT NULL DEFAULT false,
  captured_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  ext_hash       text                  -- sha256 over the fields above (for checkpoints)
);
CREATE INDEX IF NOT EXISTS ledger_ext_xid_idx ON vdb.ledger_ext (xid);

-- _ext_hash is the single source of truth for a capture row's hash.
CREATE OR REPLACE FUNCTION vdb._ext_hash(e vdb.ledger_ext) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(
    coalesce(e.ledger_id::text,'')      || '|' || coalesce(e.xid::text,'')        || '|' ||
    coalesce(e.lsn::text,'')            || '|' || coalesce(e.task_id,'')          || '|' ||
    coalesce(e.parent_session,'')       || '|' || coalesce(e.call_hash,'')        || '|' ||
    coalesce(e.override_used::text,''), 'UTF8')), 'hex');
$$;

CREATE OR REPLACE FUNCTION vdb.capture_ext() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, vdb AS $$
DECLARE e vdb.ledger_ext;
BEGIN
  IF coalesce(current_setting('vdb.v2', true), '') = 'off' THEN
    RETURN NULL;
  END IF;
  BEGIN
    e.ledger_id      := NEW.id;
    e.xid            := txid_current();
    e.lsn            := pg_current_wal_insert_lsn();
    e.task_id        := nullif(current_setting('vdb.task', true), '');
    e.parent_session := nullif(current_setting('vdb.parent_session', true), '');
    e.call_hash      := nullif(current_setting('vdb.call_hash', true), '');
    e.override_used  := coalesce(nullif(current_setting('vdb.allow_destructive', true), ''), 'off')
                          IN ('on','true','1');
    e.captured_at    := clock_timestamp();
    e.ext_hash       := vdb._ext_hash(e);
    INSERT INTO vdb.ledger_ext SELECT (e).*;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'VectoraDB ledger 2.0: capture skipped for ledger row %: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;
CREATE OR REPLACE TRIGGER vdb_ext_capture AFTER INSERT ON vdb.schema_ledger
  FOR EACH ROW EXECUTE FUNCTION vdb.capture_ext();

-- Append-only, like the ledger itself.
CREATE OR REPLACE FUNCTION vdb.deny_ext_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only — its history cannot be modified', TG_TABLE_NAME;
END;
$$;
CREATE OR REPLACE TRIGGER vdb_ext_append_only BEFORE UPDATE OR DELETE ON vdb.ledger_ext
  FOR EACH ROW EXECUTE FUNCTION vdb.deny_ext_change();
CREATE OR REPLACE TRIGGER vdb_ext_no_truncate BEFORE TRUNCATE ON vdb.ledger_ext
  FOR EACH STATEMENT EXECUTE FUNCTION vdb.deny_ext_change();
REVOKE UPDATE, DELETE, TRUNCATE ON vdb.ledger_ext FROM PUBLIC;
GRANT SELECT ON vdb.ledger_ext TO vdbclient;
GRANT EXECUTE ON FUNCTION vdb._ext_hash(vdb.ledger_ext) TO vdbclient;

-- ── Checkpoints: tamper-evidence anchored outside the database ─────────────
-- A checkpoint commits to a contiguous range of ledger ids with a Merkle root
-- over each row's recomputed hash and capture hash. The engine writes the same
-- record to a read-only anchor file outside the database
-- (docs/ledger-anchor-format.md). Integrity checks trust the anchor files, so
-- edits, deletions (including of the newest anchored rows) and a wiped ledger are
-- detected even by someone able to rewrite this database and its hash chain.
CREATE TABLE IF NOT EXISTS vdb.ledger_checkpoints (
  id            bigserial PRIMARY KEY,
  from_id       bigint  NOT NULL,             -- first ledger id covered
  to_id         bigint  NOT NULL,             -- last ledger id covered
  entry_count   integer NOT NULL,             -- ledger rows present in [from_id, to_id]
  last_row_hash text,                         -- recomputed hash of the row at to_id
  merkle_root   text    NOT NULL,
  prev_root     text    NOT NULL DEFAULT '',  -- merkle_root of the previous checkpoint
  algorithm     text    NOT NULL,
  anchor_uri    text,                         -- where the engine wrote the anchor
  created_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (to_id >= from_id AND entry_count > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS ledger_checkpoints_from_idx ON vdb.ledger_checkpoints (from_id);

-- Checkpoints must continue exactly where the previous one ended, chained by
-- root, so a concurrent or replayed checkpoint can't overlap or fork the sequence.
CREATE OR REPLACE FUNCTION vdb.checkpoint_contiguous() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE last_to bigint; last_root text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('vdb.ledger_checkpoints'));
  SELECT to_id, merkle_root INTO last_to, last_root
    FROM vdb.ledger_checkpoints ORDER BY to_id DESC LIMIT 1;
  IF NEW.from_id <> coalesce(last_to, 0) + 1 THEN
    RAISE EXCEPTION 'checkpoint must start at ledger id % (got %)', coalesce(last_to, 0) + 1, NEW.from_id;
  END IF;
  IF NEW.prev_root <> coalesce(last_root, '') THEN
    RAISE EXCEPTION 'checkpoint prev_root does not match the previous checkpoint';
  END IF;
  RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER vdb_checkpoint_contiguous BEFORE INSERT ON vdb.ledger_checkpoints
  FOR EACH ROW EXECUTE FUNCTION vdb.checkpoint_contiguous();
CREATE OR REPLACE TRIGGER vdb_checkpoint_append_only BEFORE UPDATE OR DELETE ON vdb.ledger_checkpoints
  FOR EACH ROW EXECUTE FUNCTION vdb.deny_ext_change();
CREATE OR REPLACE TRIGGER vdb_checkpoint_no_truncate BEFORE TRUNCATE ON vdb.ledger_checkpoints
  FOR EACH STATEMENT EXECUTE FUNCTION vdb.deny_ext_change();
REVOKE UPDATE, DELETE, TRUNCATE ON vdb.ledger_checkpoints FROM PUBLIC;
GRANT SELECT ON vdb.ledger_checkpoints TO vdbclient;

-- Which 2.0 definition is installed (for `vdb ledger upgrade` / diagnostics).
CREATE OR REPLACE FUNCTION vdb.ledger_v2_version() RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT '2.0-phase3' $$;
GRANT EXECUTE ON FUNCTION vdb.ledger_v2_version() TO vdbclient;

SET session_replication_role = DEFAULT;
