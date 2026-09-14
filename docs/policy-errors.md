# Blackbox policy errors — contract v1

Status: **approved** (14 Sep 2026), written and reviewed before any policy-gate
code (Blackbox 2.0 Phase 5). This is a public contract: the fields below may gain
new keys, but existing keys keep their names, types and meaning.

## What it covers

The Blackbox policy gate checks each DDL statement against **policy rules**
before it runs. A rule either **warns** (the statement runs and the client gets a
notice) or **blocks** (the statement is refused with an error). This document
fixes exactly what a client — a human in `psql`, an application driver, an agent
over MCP — receives in each case, so tools can react without parsing prose.

It does **not** change the existing guardrail. `DROP TABLE` / `DROP SCHEMA`
blocked through `vdb.policy` keep today's error, byte for byte:

```
ERROR:  VectoraDB guardrail: DROP TABLE is blocked by policy (set vdb.allow_destructive=on to override)
HINT:   Only superusers and members of vdb_admin may override. Grant it with: vdb admin grant <email>
SQLSTATE 42501 (insufficient_privilege)
```

The gate runs after that guardrail (event trigger `vdb_policy_start`, which sorts
after `vdb_guard_start`), so a statement the guardrail blocks never reaches it.

## Block: an ERROR with SQLSTATE `VDB01`

| Part | Value |
|---|---|
| Severity | `ERROR` — the statement and its transaction are rolled back |
| SQLSTATE | **`VDB01`** (custom; never used by PostgreSQL) |
| MESSAGE | `Blackbox policy: <reason> (rule <rule_id>)` — human text, **not** stable |
| DETAIL | one-line JSON object, defined below — **stable** |
| HINT | the next step in plain words — human text, **not** stable |

Example in `psql`:

```
ERROR:  Blackbox policy: changing a column type rewrites the table and can break readers (rule alter-column-type)
DETAIL:  {"v":1,"rule_id":"alter-column-type","action":"block","command":"ALTER TABLE","matched":"\\malter\\M[^;]*\\mtype\\M","reason":"changing a column type rewrites the table and can break readers","hint":"Try it on a branch first: vdb branch create try-it","override":"vdb_admin","evaluation_id":42,"blackbox_id":918,"impact":null}
HINT:  Try it on a branch first (vdb branch create try-it), or ask a Blackbox admin to allow rule alter-column-type for this session.
```

The blocked attempt is recorded in Blackbox as a `BLOCKED` entry with risk
`policy` (written through a separate connection, so it survives the rollback —
the same mechanism the guardrail uses), and as a row in
`vdb.ledger_policy_evaluations`.

## Warn: a NOTICE with SQLSTATE `VDB02`

The statement runs normally. The client receives, before the command completes:

| Part | Value |
|---|---|
| Severity | `NOTICE` |
| SQLSTATE | **`VDB02`** |
| MESSAGE | `Blackbox policy warning: <reason> (rule <rule_id>)` |
| DETAIL | the same JSON object with `"action":"warn"` |
| HINT | as for block |

A warned statement is recorded in `vdb.ledger_policy_evaluations`; its Blackbox
entry is written as usual (`APPLIED` or `FLAGGED`). One statement matching several
rules produces one NOTICE per warn rule; if any matching rule blocks, only that
block ERROR is raised (the first blocking rule by `rule_id` order).

## DETAIL JSON

| Key | Type | Meaning |
|---|---|---|
| `v` | integer | Contract version. `1`. |
| `rule_id` | string | Stable id of the rule (`[a-z0-9-]+`). |
| `action` | string | `"warn"` or `"block"`. |
| `command` | string | The command tag, e.g. `"ALTER TABLE"`. |
| `matched` | string or null | The rule's statement pattern that matched, or null for a command-only rule. |
| `reason` | string | Why the rule exists (the rule's own text). |
| `hint` | string | Suggested next step (the rule's own text, or a default). |
| `override` | string or null | Who may override a block: `"vdb_admin"`, or null if the rule allows no override. Always null for warn. |
| `evaluation_id` | integer or null | Row id in `vdb.ledger_policy_evaluations`; null if recording failed. |
| `blackbox_id` | integer or null | Id of the `BLOCKED` Blackbox entry (block only); null for warn or if recording failed. |
| `impact` | object or null | Reserved for impact analysis (Phase 7). Always null in v1. |

Rules for clients:
- Detect by **SQLSTATE**, then parse DETAIL as JSON. Don't parse MESSAGE or HINT.
- Ignore keys you don't know; new keys may be added in v1. Key order and whitespace
  are not significant.
- The statement text is not repeated in DETAIL (it can be large or sensitive); it is
  in the Blackbox entry referenced by `blackbox_id`.

Reading it from common drivers:

```python
# psycopg 3
except psycopg.Error as e:
    if e.diag.sqlstate == "VDB01":
        info = json.loads(e.diag.message_detail)
```

```js
// node-postgres
catch (err) { if (err.code === "VDB01") { const info = JSON.parse(err.detail) } }
```

```go
// pgx
var pgErr *pgconn.PgError
if errors.As(err, &pgErr) && pgErr.Code == "VDB01" { json.Unmarshal([]byte(pgErr.Detail), &info) }
```

Warnings arrive through each driver's notice handler (psycopg `add_notice_handler`,
node-postgres `client.on('notice')`, pgx `OnNotice`) with `sqlstate`/`code` `VDB02`.

## Overriding a block

A block can be overridden only by a superuser or a member of `vdb_admin` (the same
check as the guardrail, on `session_user`), for one rule at a time:

```sql
SET vdb.policy_allow = 'alter-column-type';        -- comma-separated rule ids
ALTER TABLE orders ALTER COLUMN total TYPE numeric;
```

The override is recorded: the evaluation row has `action = 'allowed'` and the
statement's capture row has `override_used = true`. For anyone else the setting is
ignored and the block stands. `vdb.allow_destructive` does **not** override policy
rules (it stays specific to the guardrail).

## Rules shipped by default (all `warn`)

| rule_id | Command | Matches |
|---|---|---|
| `alter-column-type` | `ALTER TABLE` | `… ALTER [COLUMN] … TYPE …` |
| `drop-column` | `ALTER TABLE` | `… DROP [COLUMN] …` |
| `drop-index` | `DROP INDEX` | any |
| `grant-to-public` | `GRANT` | `… TO PUBLIC` |

Blocking is opt-in per rule (`vdb policy block <rule_id>`). TRUNCATE is out of
scope: it doesn't fire DDL event triggers.

## Where else the object appears

- `vdb policy check "<SQL>"` / REST `POST /api/branches/{name}/policies/check`:
  the same JSON objects, as a list, without running the statement.
- MCP `execute_change` (Phase 6): on a block the tool result carries this JSON
  object under `"policy"`.

## Decisions (review of 14 Sep 2026)

1. **Codes:** `VDB01` for a block (ERROR), `VDB02` for a warning (NOTICE).
2. **Override:** superusers and `vdb_admin` members only, per rule, with
   `SET vdb.policy_allow = '<rule ids>'`; the override is recorded.
3. **Defaults:** all four shipped rules warn; blocking is opt-in per rule.
4. **Recording:** blocked attempts become `BLOCKED` Blackbox entries with risk
   `policy`, as the guardrail's do.
