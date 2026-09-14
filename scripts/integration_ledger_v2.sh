#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Schema Ledger 2.0 integration checks. Run inside the Linux dev VM (ZFS + Docker):
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

echo
echo "==== ${PASS} passed, ${FAIL} failed ===="
[ "$FAIL" -eq 0 ]
