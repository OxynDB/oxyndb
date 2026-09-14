#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Blackbox 2.0 integration checks. Run inside the Linux dev VM (ZFS + Docker):
#   make integration-v2
# Section 0 pins behaviour that must NOT change while 2.0 is built alongside it;
# later sections test each phase. Complements scripts/integration_test.sh, which
# must keep passing too. Exits non-zero if any assertion fails.
set -uo pipefail

S="${VECTORADB_BIN:-/tmp/vdb}"
GATEWAY="postgresql://vectoradb@127.0.0.1:6432"
API="https://localhost:8080"
AGENTS="https://localhost:8088"
PASS=0
FAIL=0

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
# pg <container> <sql>  -> tuples-only result, as the superuser over the local socket
pg() { local c="$1"; shift; sudo docker exec "$c" psql -U vectoradb -d vectoradb -tAc "$*" 2>/dev/null; }
# gw <key> <branch> <sql>  -> psql through the gateway, stderr included
gw() { PGPASSWORD="$1" psql "$GATEWAY/$2" -tAc "$3" 2>&1; }
jget() { python3 -c 'import sys,json; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
jcols() { python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)["columns"]))'; }
# mcp_call <tool> <json-args> [env...]  -> the tool's text result
mcp_call() {
  local tool="$1" args="$2"; shift 2
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" \
    | env "$@" "$S" mcp 2>/dev/null \
    | python3 -c 'import sys,json
for line in sys.stdin:
    m=json.loads(line)
    if m.get("id")==2: print(m["result"]["content"][0]["text"])'
}

echo "### setup"
$S stop >/dev/null 2>&1; sleep 1
$S start >/dev/null 2>&1; sleep 5
USER_EMAIL="v2test@vectoradb.dev"
printf 'password123\n' | $S user create "$USER_EMAIL" >/dev/null 2>&1 || true
KEY="$($S apikey create "$USER_EMAIL" v2 2>/dev/null | grep -o 'vdb_[A-Za-z0-9_-]*')"
AUTH="Authorization: Bearer $KEY"
$S admin revoke "$USER_EMAIL" >/dev/null 2>&1 || true   # start from a non-admin user
assert_eq "test API key minted" "$([ -n "$KEY" ] && echo yes)" "yes"

echo "### 0. behaviour unchanged (characterization)"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2keep" >/dev/null
gw "$KEY" main "CREATE TABLE v2keep(x int)" >/dev/null
assert_eq "guardrail error text is unchanged" \
  "$(gw "$KEY" main "DROP TABLE v2keep" | grep -c 'VectoraDB guardrail: DROP TABLE is blocked by policy (set vdb.allow_destructive=on to override)')" "1"
assert_eq "REST ledger columns are unchanged" \
  "$(curl -sk -H "$AUTH" "$API/api/branches/main/ledger?limit=1" | jcols)" \
  "at,actor,actor_kind,tool,branch,command_tag,object_identity,statement,status,risk"
assert_eq "REST verify columns are unchanged" \
  "$(curl -sk -H "$AUTH" "$API/api/branches/main/ledger/verify" | jcols)" \
  "legacy,chained,broken,first_broken"
# The row_hash formula must never change: recompute a fixed row in SQL and in Python.
SQLHASH="$(pg vec-main "SELECT vdb._ledger_hash(ROW(42,'2026-01-02 03:04:05+00','priya','human','psql','s1','main','CREATE TABLE','table','public.t','CREATE TABLE t()','APPLIED',NULL,'abc',NULL)::vdb.schema_ledger)")"
PYHASH="$(python3 -c 'import hashlib;print(hashlib.sha256("abc|42|2026-01-02 03:04:05|priya|human|psql|s1|main|CREATE TABLE|table|public.t|CREATE TABLE t()|APPLIED|".encode()).hexdigest())')"
assert_eq "row_hash formula is unchanged" "$SQLHASH" "$PYHASH"
assert_eq "CLI ledger verify still reports intact" "$($S ledger verify 2>&1 | grep -c 'ledger intact')" "1"

echo "### 1a. H1: point-in-time restore uses the generated MinIO credentials"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2pit; CREATE TABLE v2pit(id int); INSERT INTO v2pit SELECT generate_series(1,3);" >/dev/null
$S backup create >/dev/null 2>&1
pg vec-main "SELECT pg_switch_wal();" >/dev/null; sleep 3
RESTORE_OUT="$($S restore --to latest 2>&1)"
assert_eq "PITR restores 3 rows" "$(pg vec-restore 'SELECT count(*) FROM v2pit')" "3"
assert_eq "restore no longer prints a hardcoded password" "$(echo "$RESTORE_OUT" | grep -c 'PGPASSWORD=vectoradb')" "0"
assert_eq "restore container has no minioadmin credentials" \
  "$(sudo docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' vec-restore 2>/dev/null | grep -c '=minioadmin$')" "0"
sudo docker rm -f vec-restore >/dev/null 2>&1

echo "### 1b. H2: only superusers and vdb_admin members may override the guardrail"
assert_eq "ledger upgrade succeeds on main" "$($S ledger upgrade main >/dev/null 2>&1; echo $?)" "0"
assert_eq "override check is installed" "$(pg vec-main "SELECT to_regprocedure('vdb._may_override()') IS NOT NULL")" "t"
assert_eq "vdb_admin role exists" "$(pg vec-main "SELECT count(*) FROM pg_roles WHERE rolname='vdb_admin'")" "1"
gw "$KEY" main "CREATE TABLE IF NOT EXISTS v2guard(x int)" >/dev/null
assert_eq "non-admin override is refused" \
  "$(gw "$KEY" main "SET vdb.allow_destructive=on; DROP TABLE v2guard" | grep -c 'blocked by policy')" "1"
assert_eq "refused override leaves the table in place" "$(pg vec-main "SELECT to_regclass('public.v2guard') IS NOT NULL")" "t"
assert_eq "refusal carries the vdb_admin hint" \
  "$(gw "$KEY" main "SET vdb.allow_destructive=on; DROP TABLE v2guard" | grep -c 'vdb_admin')" "1"
$S admin grant "$USER_EMAIL" --branch main >/dev/null 2>&1
assert_eq "admin list shows the granted user" "$($S admin list --branch main 2>&1 | grep -c "$USER_EMAIL")" "1"
gw "$KEY" main "SET vdb.allow_destructive=on; DROP TABLE v2guard" >/dev/null
assert_eq "admin override drops the table" "$(pg vec-main "SELECT to_regclass('public.v2guard') IS NULL")" "t"
$S admin revoke "$USER_EMAIL" --branch main >/dev/null 2>&1
gw "$KEY" main "CREATE TABLE IF NOT EXISTS v2guard(x int)" >/dev/null
assert_eq "revoked user is refused again" \
  "$(gw "$KEY" main "SET vdb.allow_destructive=on; DROP TABLE v2guard" | grep -c 'blocked by policy')" "1"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2guard; DROP TABLE IF EXISTS v2keep; DROP TABLE IF EXISTS v2pit" >/dev/null
assert_eq "superuser override still works (imports/pipelines path)" "$(pg vec-main "SELECT to_regclass('public.v2keep') IS NULL")" "t"

echo "### 1c. H3: agents and MCP run without superuser"
curl -sk -H "$AUTH" -X DELETE "$AGENTS/agents/v2itest/branch" >/dev/null 2>&1
DSN="$(curl -sk -H "$AUTH" -X POST "$AGENTS/agents/v2itest/branch" | jget dsn)"
assert_eq "agent DSN logs in as the agent's own role" \
  "$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).username)' "$DSN")" "agent-v2itest"
assert_eq "agent role is not a superuser" "$(psql "$DSN" -tAc "SELECT rolsuper FROM pg_roles WHERE rolname=session_user" 2>/dev/null)" "f"
psql "$DSN" -c "CREATE TABLE a(x int); INSERT INTO a VALUES (7);" >/dev/null 2>&1
assert_eq "agent DB is usable via its DSN" "$(psql "$DSN" -tAc 'SELECT x FROM a' 2>/dev/null)" "7"
assert_eq "agent change attributed to the agent" \
  "$(pg vec-agent-v2itest "SELECT actor||'/'||actor_kind FROM vdb.schema_ledger WHERE command_tag='CREATE TABLE' AND object_identity='public.a'")" "agent-v2itest/agent"
assert_eq "agent cannot disable triggers (session_replication_role)" \
  "$(psql "$DSN" -tAc "SET session_replication_role=replica" 2>&1 | grep -c 'permission denied')" "1"
assert_eq "agent cannot override the guardrail" \
  "$(psql "$DSN" -tAc "SET vdb.allow_destructive=on; DROP TABLE a" 2>&1 | grep -c 'blocked by policy')" "1"
assert_eq "MCP list_branches does not expose a password" \
  "$(mcp_call list_branches '{}' | grep -c 'postgresql://agent-v2itest@')" "1"
assert_eq "MCP run_sql runs as the client role" "$(mcp_call run_sql '{"sql":"SELECT session_user"}' | grep -c 'vdbclient')" "1"
assert_eq "MCP run_sql cannot disable triggers" \
  "$(mcp_call run_sql '{"sql":"SET session_replication_role=replica"}' | grep -c 'permission denied')" "1"
assert_eq "VECTORADB_MCP_SUPERUSER=1 restores the old role" \
  "$(mcp_call run_sql '{"sql":"SELECT session_user"}' VECTORADB_MCP_SUPERUSER=1 | grep -c 'vectoradb')" "1"
curl -sk -H "$AUTH" -X DELETE "$AGENTS/agents/v2itest/branch" >/dev/null 2>&1

echo "### 2. ledger 2.0 capture (xid, LSN, provenance, override use)"
# pgerr keeps stderr, for assertions on error messages (pg discards it).
pgerr() { local c="$1"; shift; sudo docker exec "$c" psql -U vectoradb -d vectoradb -tAc "$*" 2>&1; }
assert_eq "ledger 2.0 is installed on main at start" "$(pg vec-main "SELECT vdb.ledger_v2_version()")" "2.0-phase3"
assert_eq "ledger upgrade is idempotent (run twice)" \
  "$($S ledger upgrade main >/dev/null 2>&1 && $S ledger upgrade main >/dev/null 2>&1; echo $?)" "0"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2cap; DROP TABLE IF EXISTS v2off; DROP TABLE IF EXISTS v2safe" >/dev/null
PGOPTIONS='-c vdb.task=task-42 -c vdb.call_hash=abc123' PGPASSWORD="$KEY" psql "$GATEWAY/main" -qc "CREATE TABLE v2cap(x int)" >/dev/null 2>&1
CAPID="$(pg vec-main "SELECT max(id) FROM vdb.schema_ledger WHERE command_tag='CREATE TABLE' AND object_identity='public.v2cap'")"
assert_eq "every new ledger row gets a capture row" "$(pg vec-main "SELECT count(*) FROM vdb.ledger_ext WHERE ledger_id=$CAPID")" "1"
assert_eq "capture records the transaction and WAL position" \
  "$(pg vec-main "SELECT (xid IS NOT NULL AND lsn IS NOT NULL)::text FROM vdb.ledger_ext WHERE ledger_id=$CAPID")" "true"
assert_eq "capture records task and call hash from the session" \
  "$(pg vec-main "SELECT task_id||'/'||call_hash FROM vdb.ledger_ext WHERE ledger_id=$CAPID")" "task-42/abc123"
assert_eq "capture hash verifies" \
  "$(pg vec-main "SELECT (e.ext_hash = vdb._ext_hash(e))::text FROM vdb.ledger_ext e WHERE ledger_id=$CAPID")" "true"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE v2cap" >/dev/null
assert_eq "override use is recorded" \
  "$(pg vec-main "SELECT e.override_used::text FROM vdb.ledger_ext e JOIN vdb.schema_ledger s ON s.id=e.ledger_id WHERE s.command_tag='DROP TABLE' AND s.object_identity='public.v2cap' ORDER BY s.id DESC LIMIT 1")" "true"
# Fail-safe: a capture that errors must never block the user's DDL.
pg vec-main "ALTER TABLE vdb.ledger_ext ADD CONSTRAINT v2_test_fail CHECK (false) NOT VALID" >/dev/null
SAFEMARK="$(pg vec-main "SELECT coalesce(max(id), 0) FROM vdb.schema_ledger")"   # count only this run's rows
gw "$KEY" main "CREATE TABLE v2safe(x int)" >/dev/null
assert_eq "a failing capture does not block DDL" "$(pg vec-main "SELECT to_regclass('public.v2safe') IS NOT NULL")" "t"
assert_eq "the base ledger still records that DDL" \
  "$(pg vec-main "SELECT count(*) FROM vdb.schema_ledger WHERE command_tag='CREATE TABLE' AND object_identity='public.v2safe' AND id > $SAFEMARK")" "1"
pg vec-main "ALTER TABLE vdb.ledger_ext DROP CONSTRAINT v2_test_fail" >/dev/null
# Kill switch: vdb.v2=off stops capture for new sessions.
pg vec-main "ALTER DATABASE vectoradb SET vdb.v2 = 'off'" >/dev/null
gw "$KEY" main "CREATE TABLE v2off(x int)" >/dev/null
OFFID="$(pg vec-main "SELECT max(id) FROM vdb.schema_ledger WHERE object_identity='public.v2off'")"
assert_eq "kill switch disables capture" "$(pg vec-main "SELECT count(*) FROM vdb.ledger_ext WHERE ledger_id=$OFFID")" "0"
pg vec-main "ALTER DATABASE vectoradb RESET vdb.v2" >/dev/null
assert_eq "capture table is append-only" \
  "$(pgerr vec-main "DELETE FROM vdb.ledger_ext WHERE ledger_id=$CAPID" | grep -c 'append-only')" "1"
assert_eq "clients cannot write capture rows" \
  "$(gw "$KEY" main "INSERT INTO vdb.ledger_ext(ledger_id) VALUES (-1)" | grep -c 'permission denied')" "1"
assert_eq "base hash chain still verifies after 2.0 activity" "$($S ledger verify 2>&1 | grep -c 'ledger intact')" "1"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2off; DROP TABLE IF EXISTS v2safe" >/dev/null

echo "### 3. checkpoints, anchors and the independent verifier"
VERIFY="${VECTORADB_VERIFY_BIN:-/tmp/vdb-verify}"
ANCH="${VECTORADB_ANCHOR_DIR:-$HOME/.vectoradb/anchors}"
assert_eq "checkpoints table is installed" "$(pg vec-main "SELECT to_regclass('vdb.ledger_checkpoints') IS NOT NULL")" "t"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2cp" >/dev/null
gw "$KEY" main "CREATE TABLE v2cp(x int)" >/dev/null
CP_OUT="$($S ledger checkpoint main 2>&1)"
assert_eq "manual checkpoint anchors new ledger entries" "$(echo "$CP_OUT" | grep -c '^checkpoint #')" "1"
CP_FILE="$(echo "$CP_OUT" | awk '$1=="anchor"{print $2}')"
assert_eq "anchor file is read-only" "$(stat -c '%a' "$CP_FILE" 2>/dev/null)" "444"
assert_eq "anchor uses the published format" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["format"])' "$CP_FILE" 2>/dev/null)" "vectoradb-ledger-anchor/1"
assert_eq "a checkpoint with nothing new is a no-op" "$($S ledger checkpoint main 2>&1 | grep -c 'nothing new')" "1"
assert_eq "database refuses a checkpoint that doesn't continue the sequence" \
  "$(pgerr vec-main "INSERT INTO vdb.ledger_checkpoints(from_id,to_id,entry_count,merkle_root,prev_root,algorithm) VALUES (1,1,1,'x','','t')" | grep -c 'must start at')" "1"
assert_eq "checkpoints are append-only" "$(pgerr vec-main "DELETE FROM vdb.ledger_checkpoints" | grep -c 'append-only')" "1"

# fresh_branch <name>: a clean branch whose 3 newest ledger entries are anchored.
fresh_branch() {
  $S branch delete "$1" >/dev/null 2>&1; rm -rf "$ANCH/$1"
  $S branch create "$1" >/dev/null 2>&1
  $S ledger upgrade "$1" >/dev/null 2>&1
  for t in v2i_a v2i_b v2i_c; do pg "vec-$1" "CREATE TABLE $t(x int)" >/dev/null; done
  $S ledger checkpoint "$1" >/dev/null 2>&1
}
integrity_state() { $S ledger integrity "$1" 2>&1 | head -1 | grep -o 'INTACT\|TAMPERED'; }

fresh_branch v2int
V2DSN="postgresql://vectoradb:$KEY@127.0.0.1:6432/v2int"
assert_eq "integrity is INTACT on an untampered branch" "$(integrity_state v2int)" "INTACT"
assert_eq "REST integrity agrees" "$(curl -sk -H "$AUTH" "$API/api/branches/v2int/ledger/integrity" | jget intact)" "True"
assert_eq "MCP ledger_integrity agrees" "$(mcp_call ledger_integrity '{"branch":"v2int"}' | grep -c 'INTACT')" "1"
"$VERIFY" --dsn "$V2DSN" --anchors "$ANCH/v2int" >/dev/null 2>&1
assert_eq "vdb-verify on the live database agrees (exit 0)" "$?" "0"
$S ledger export v2int > /tmp/v2int.jsonl 2>/dev/null
assert_eq "export has one line per ledger entry" "$(wc -l < /tmp/v2int.jsonl | tr -d ' ')" "$(pg vec-v2int "SELECT count(*) FROM vdb.schema_ledger")"
"$VERIFY" --export /tmp/v2int.jsonl --anchors "$ANCH/v2int" >/dev/null 2>&1
assert_eq "vdb-verify on the exported file agrees (exit 0)" "$?" "0"

# Forged edit: change an anchored entry, then rewrite the whole hash chain so the
# in-database check passes again. Only the anchors can catch this.
FORGE="SET session_replication_role = replica;
UPDATE vdb.schema_ledger SET statement = statement || ' -- forged' WHERE id = (SELECT max(id) FROM vdb.schema_ledger);
DO \$\$ DECLARE r record; prev text := ''; BEGIN
  FOR r IN SELECT id FROM vdb.schema_ledger WHERE row_hash IS NOT NULL ORDER BY id LOOP
    UPDATE vdb.schema_ledger SET prev_hash = prev WHERE id = r.id;
    UPDATE vdb.schema_ledger s SET row_hash = vdb._ledger_hash(s) WHERE s.id = r.id RETURNING s.row_hash INTO prev;
  END LOOP; END \$\$;"
pg vec-v2int "$FORGE" >/dev/null
assert_eq "forged edit: the in-database hash-chain check is fooled" "$($S ledger verify v2int 2>&1 | grep -c 'ledger intact')" "1"
assert_eq "forged edit: integrity against the anchors is TAMPERED" "$(integrity_state v2int)" "TAMPERED"
"$VERIFY" --dsn "$V2DSN" --anchors "$ANCH/v2int" >/dev/null 2>&1
assert_eq "forged edit: vdb-verify exits 1" "$?" "1"

fresh_branch v2int
pg vec-v2int "SET session_replication_role = replica; DELETE FROM vdb.schema_ledger WHERE id = (SELECT max(id) FROM vdb.schema_ledger)" >/dev/null
assert_eq "deleted newest anchored entry: the in-database check still passes" "$($S ledger verify v2int 2>&1 | grep -c 'ledger intact')" "1"
assert_eq "deleted newest anchored entry: integrity is TAMPERED" "$(integrity_state v2int)" "TAMPERED"

fresh_branch v2int
pg vec-v2int "SET session_replication_role = replica; DELETE FROM vdb.schema_ledger" >/dev/null
assert_eq "wiped ledger: integrity is TAMPERED" "$(integrity_state v2int)" "TAMPERED"

fresh_branch v2int
pg vec-v2int "SET session_replication_role = replica; DELETE FROM vdb.ledger_checkpoints" >/dev/null
assert_eq "the anchor files, not the database's copy, are the source of truth" "$(integrity_state v2int)" "INTACT"
$S branch delete v2int >/dev/null 2>&1; rm -rf "$ANCH/v2int" /tmp/v2int.jsonl

echo "### 3b. scheduled checkpoints"
$S stop >/dev/null 2>&1; sleep 1
VECTORADB_CHECKPOINT_INTERVAL=15s $S start >/dev/null 2>&1; sleep 5
BEFORE="$(pg vec-main "SELECT count(*) FROM vdb.ledger_checkpoints")"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2sched" >/dev/null
gw "$KEY" main "CREATE TABLE v2sched(x int)" >/dev/null
for i in $(seq 1 12); do
  [ "$(pg vec-main "SELECT count(*) FROM vdb.ledger_checkpoints")" -gt "$BEFORE" ] && break
  sleep 5
done
assert_eq "the scheduler anchors new entries on its own" \
  "$([ "$(pg vec-main "SELECT count(*) FROM vdb.ledger_checkpoints")" -gt "$BEFORE" ] && echo yes)" "yes"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2sched; DROP TABLE IF EXISTS v2cp" >/dev/null
$S stop >/dev/null 2>&1; sleep 1
$S start >/dev/null 2>&1; sleep 5

echo "### 4. branch from just before a ledger entry"
# Three full restores (CLI by xid, MCP by time, REST) — expect a few minutes.
for b in v2bb v2bb-rest v2bb-time v2bb-x; do $S branch delete "$b" >/dev/null 2>&1; done
# main's integrity result before branch-before runs. Not necessarily INTACT: the
# existing suite's resets delete main's ledger rows, which earlier anchors catch.
main_integrity() { $S ledger integrity main 2>&1 | grep '✗' | sort; }   # its problems, if any
MAIN_INTEGRITY_BEFORE="$(main_integrity)"
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2bb_keep; DROP TABLE IF EXISTS v2bb_old; DROP TABLE IF EXISTS v2bb_target; DROP TABLE IF EXISTS v2bb_after" >/dev/null
gw "$KEY" main "CREATE TABLE v2bb_keep(x int)" >/dev/null
gw "$KEY" main "INSERT INTO v2bb_keep SELECT generate_series(1,5)" >/dev/null
$S backup create >/dev/null 2>&1
gw "$KEY" main "INSERT INTO v2bb_keep SELECT generate_series(6,7)" >/dev/null   # after the backup, before the changes
sleep 1
pg vec-main "SET vdb.v2 = 'off'; CREATE TABLE v2bb_old(x int)" >/dev/null       # an entry without capture (time fallback)
OLDID="$(pg vec-main "SELECT max(id) FROM vdb.schema_ledger WHERE object_identity = 'public.v2bb_old'")"
sleep 1
gw "$KEY" main "CREATE TABLE v2bb_target(x int)" >/dev/null
TID="$(pg vec-main "SELECT max(id) FROM vdb.schema_ledger WHERE object_identity = 'public.v2bb_target'")"
gw "$KEY" main "INSERT INTO v2bb_keep VALUES (8)" >/dev/null
gw "$KEY" main "CREATE TABLE v2bb_after(x int)" >/dev/null
assert_eq "the target entry has a captured transaction id" \
  "$(pg vec-main "SELECT (xid IS NOT NULL)::text FROM vdb.ledger_ext WHERE ledger_id = $TID")" "true"
assert_eq "the fallback entry has none" \
  "$(pg vec-main "SELECT count(*) FROM vdb.ledger_ext WHERE ledger_id = $OLDID")" "0"
assert_eq "vdb ledger entries lists the entry id" "$($S ledger entries --limit 10 | awk '{print $1}' | grep -cx "$TID")" "1"
assert_eq "REST ledger entries lists it" \
  "$(curl -sk -H "$AUTH" "$API/api/branches/main/ledger/entries?limit=10" | python3 -c 'import sys,json; print(sum(1 for e in json.load(sys.stdin) if e["id"] == int(sys.argv[1])))' "$TID")" "1"
assert_eq "MCP ledger_entries lists it" "$(mcp_call ledger_entries '{"limit":10}' | awk '{print $1}' | grep -cx "$TID")" "1"

OUT="$($S ledger branch-before "$TID" --as v2bb 2>&1)"
assert_eq "CLI branch-before succeeds" "$(echo "$OUT" | grep -c 'is ready')" "1"
assert_eq "it recovered to the entry's transaction id" "$(echo "$OUT" | grep -c 'target     xid')" "1"
assert_eq "the new branch is running" "$(sudo docker inspect -f '{{.State.Status}}' vec-v2bb 2>/dev/null)" "running"
assert_eq "rows written before the change are there (including after the backup)" "$(pg vec-v2bb 'SELECT count(*) FROM v2bb_keep')" "7"
assert_eq "an earlier change is there" "$(pg vec-v2bb "SELECT count(*) FROM pg_tables WHERE tablename = 'v2bb_old'")" "1"
assert_eq "the change itself is not" "$(pg vec-v2bb "SELECT count(*) FROM pg_tables WHERE tablename = 'v2bb_target'")" "0"
assert_eq "later changes are not" "$(pg vec-v2bb "SELECT count(*) FROM pg_tables WHERE tablename = 'v2bb_after'")" "0"
assert_eq "its ledger stops before the entry" "$(pg vec-v2bb "SELECT count(*) FROM vdb.schema_ledger WHERE id >= $TID")" "0"
assert_eq "no recovery settings are left behind" \
  "$(pg vec-v2bb "SELECT count(*) FROM pg_file_settings WHERE name LIKE 'recovery_target%' OR name = 'restore_command'")" "0"
assert_eq "it is reachable through the gateway" "$(gw "$KEY" v2bb 'SELECT count(*) FROM v2bb_keep')" "7"
assert_eq "the guardrail is active on it" "$(gw "$KEY" v2bb 'DROP TABLE v2bb_keep' | grep -c 'guardrail')" "1"
assert_eq "main is untouched" \
  "$(pg vec-main "SELECT count(*) FROM pg_tables WHERE tablename IN ('v2bb_target','v2bb_after')")|$(pg vec-main 'SELECT count(*) FROM v2bb_keep')" "2|8"
assert_eq "main's ledger integrity result is unchanged" "$(main_integrity)" "$MAIN_INTEGRITY_BEFORE"

assert_eq "an existing branch name is refused" \
  "$($S ledger branch-before "$TID" --as v2bb 2>&1 | grep -c 'already exists')" "1"
gw "$KEY" main "DROP TABLE v2bb_keep" >/dev/null   # blocked by the guardrail: a BLOCKED entry
BID="$(pg vec-main "SELECT max(id) FROM vdb.schema_ledger WHERE status = 'BLOCKED'")"
assert_eq "a BLOCKED entry is refused" "$($S ledger branch-before "$BID" --as v2bb-x 2>&1 | grep -c 'BLOCKED')" "1"
assert_eq "a refused request leaves nothing behind" "$(sudo docker inspect vec-v2bb-x >/dev/null 2>&1 || echo none)" "none"
assert_eq "an unknown entry is refused" "$($S ledger branch-before 999999999 --as v2bb-x 2>&1 | grep -c 'not found')" "1"
assert_eq "a source other than main is refused" "$($S ledger branch-before "$TID" --branch v2bb --as v2bb-x 2>&1 | grep -c 'only main')" "1"
assert_eq "a bad entry id is a usage error" "$($S ledger branch-before abc >/dev/null 2>&1; echo $?)" "2"
assert_eq "REST: unknown entry is 404" \
  "$(curl -sk -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" "$API/api/branches/main/ledger/999999999/branch")" "404"
assert_eq "REST: BLOCKED entry is 400" \
  "$(curl -sk -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" "$API/api/branches/main/ledger/$BID/branch")" "400"
assert_eq "REST: existing name is 409" \
  "$(curl -sk -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -d '{"name":"v2bb"}' "$API/api/branches/main/ledger/$TID/branch")" "409"
assert_eq "MCP lists branch_before_change" \
  "$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$S" mcp 2>/dev/null | grep -c 'branch_before_change')" "1"
assert_eq "MCP: BLOCKED entry is refused" "$(mcp_call branch_before_change "{\"entry_id\":$BID,\"name\":\"v2bb-x\"}" | grep -c 'BLOCKED')" "1"

assert_eq "REST branch-before creates the branch" \
  "$(curl -sk --max-time 1200 -X POST -H "$AUTH" -d '{"name":"v2bb-rest"}' "$API/api/branches/main/ledger/$TID/branch" | jget branch)" "v2bb-rest"
assert_eq "REST branch holds main before the change" \
  "$(pg vec-v2bb-rest "SELECT count(*) FROM pg_tables WHERE tablename = 'v2bb_target'")|$(pg vec-v2bb-rest 'SELECT count(*) FROM v2bb_keep')" "0|7"

assert_eq "MCP branch-before by time (entry without capture) succeeds" \
  "$(mcp_call branch_before_change "{\"entry_id\":$OLDID,\"name\":\"v2bb-time\"}" | grep -c 'recovered to time')" "1"
assert_eq "time fallback excludes the change and keeps earlier rows" \
  "$(pg vec-v2bb-time "SELECT count(*) FROM pg_tables WHERE tablename = 'v2bb_old'")|$(pg vec-v2bb-time 'SELECT count(*) FROM v2bb_keep')" "0|7"

$S branch delete v2bb >/dev/null 2>&1
assert_eq "the branch deletes like any other" "$(sudo docker inspect vec-v2bb >/dev/null 2>&1 || echo gone)" "gone"
for b in v2bb-rest v2bb-time v2bb-x; do $S branch delete "$b" >/dev/null 2>&1; done
pg vec-main "SET vdb.allow_destructive=on; DROP TABLE IF EXISTS v2bb_keep; DROP TABLE IF EXISTS v2bb_old; DROP TABLE IF EXISTS v2bb_target; DROP TABLE IF EXISTS v2bb_after" >/dev/null

echo "### 5. Blackbox names (aliases of the ledger command, routes and tools)"
assert_eq "vdb blackbox verify matches vdb ledger verify" "$($S blackbox verify main 2>&1)" "$($S ledger verify main 2>&1)"
assert_eq "vdb blackbox entries matches vdb ledger entries" "$($S blackbox entries --limit 5 2>&1)" "$($S ledger entries --limit 5 2>&1)"
assert_eq "vdb blackbox integrity matches vdb ledger integrity" \
  "$($S blackbox integrity main 2>&1 | head -1 | grep -o 'INTACT\|TAMPERED')" "$($S ledger integrity main 2>&1 | head -1 | grep -o 'INTACT\|TAMPERED')"
assert_eq "REST /blackbox/verify matches /ledger/verify" \
  "$(curl -sk -H "$AUTH" "$API/api/branches/main/blackbox/verify")" "$(curl -sk -H "$AUTH" "$API/api/branches/main/ledger/verify")"
assert_eq "REST /blackbox keeps the ledger columns" \
  "$(curl -sk -H "$AUTH" "$API/api/branches/main/blackbox?limit=1" | jcols)" \
  "at,actor,actor_kind,tool,branch,command_tag,object_identity,statement,status,risk"
assert_eq "REST /blackbox/entries answers" \
  "$(curl -sk -o /dev/null -w '%{http_code}' -H "$AUTH" "$API/api/branches/main/blackbox/entries?limit=1")" "200"
assert_eq "REST /blackbox routes require auth like the originals" \
  "$(curl -sk -o /dev/null -w '%{http_code}' "$API/api/branches/main/blackbox/verify")" "401"
assert_eq "MCP lists both the Blackbox and the original tool names" \
  "$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$S" mcp 2>/dev/null | python3 -c 'import sys,json; n={t["name"] for t in json.load(sys.stdin)["result"]["tools"]}; print(all(x in n for x in ["verify_blackbox","blackbox_integrity","blackbox_entries","verify_ledger","ledger_integrity","ledger_entries"]))')" "True"
assert_eq "MCP blackbox_integrity matches ledger_integrity" \
  "$(mcp_call blackbox_integrity '{"branch":"main"}' | head -1 | grep -o 'INTACT\|TAMPERED')" "$(mcp_call ledger_integrity '{"branch":"main"}' | head -1 | grep -o 'INTACT\|TAMPERED')"
assert_eq "MCP verify_blackbox matches verify_ledger" \
  "$(mcp_call verify_blackbox '{"branch":"main"}')" "$(mcp_call verify_ledger '{"branch":"main"}')"

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
[ "$FAIL" -eq 0 ]
