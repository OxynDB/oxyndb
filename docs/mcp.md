<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# VectoraDB over MCP

`vdb mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io) on
stdio, so an agent framework can get its own disposable Postgres database, run
SQL, see exactly what it changed, and throw the database away — through one
standard interface, with no HTTP client to write.

It is newline-delimited JSON-RPC 2.0 on stdin/stdout. **stdout carries the
protocol**, so every log line goes to stderr; a tool that prints to stdout will
corrupt the session.

## Point a client at it

Most clients take a command and arguments. The command is `vdb`, the argument is
`mcp`:

```json
{
  "mcpServers": {
    "vectoradb": {
      "command": "vdb",
      "args": ["mcp"]
    }
  }
}
```

That is the whole configuration. `vdb` must be on the client's `PATH` (the
installer puts it there) and VectoraDB must be running — `vdb start` — because
the tools talk to the same engine the CLI does.

On macOS and Windows the engine runs inside a VM or WSL distro, and `vdb mcp`
forwards into it automatically, so the config above is identical on every
platform.

Check it by hand before wiring up a client:

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | vdb mcp
```

You should get two JSON lines back: the server's capabilities, then the tools.

## The tools

Branches — a branch is a copy-on-write clone of `main`, created in seconds:

| Tool | What it does | Arguments |
|---|---|---|
| `create_branch` | Creates an isolated database for an agent and returns its DSN | `agent_id` (required) |
| `list_branches` | Lists the active agent branches and their DSNs | — |
| `delete_branch` | Deletes an agent's branch and all its data | `agent_id` (required) |
| `run_sql` | Runs SQL on a branch and returns the result | `sql` (required), `branch` |

Blackbox — the tamper-evident record of every schema change:

| Tool | What it does | Arguments |
|---|---|---|
| `changes` | Recent schema changes: who changed what, when, with which tool | `branch`, `limit` |
| `verify_ledger` | Recomputes the hash chain to check nothing was altered | `branch` |
| `ledger_integrity` | Checks the record against anchors stored outside the database — catches edited, deleted or wiped history | `branch` |
| `ledger_entries` | Newest entries with their ids (feed one to `branch_before_change`) | `branch`, `limit` |
| `branch_before_change` | New branch holding `main` as it was just before a given entry | `entry_id` (required), `branch`, `name` |
| `blackbox_diff` | Where two branches' histories split, what each changed since, and objects both changed | `a`, `b` (both required) |

`verify_blackbox`, `blackbox_integrity` and `blackbox_entries` are listed too and
do exactly the same as `verify_ledger`, `ledger_integrity` and `ledger_entries` —
Blackbox is the product name, and both spellings work everywhere.

Changing schema safely:

| Tool | What it does | Arguments |
|---|---|---|
| `impact` | Before you change something: what depends on it, which other branches have it, the policy verdict, and a risk score | `sql` or `object` (+ `column`), `branch` |
| `policy_check` | Which policy rules a statement would trigger — warn or block — without running it | `sql` (required), `branch` |
| `execute_change` | Runs a change with provenance attached (session, task, parent session), after a policy preview; returns what happened and the Blackbox entries it wrote | `sql` (required), `branch`, `task_id`, `parent_session_id`, `dry_run` |

`execute_change` is the one to reach for when an agent alters a schema:
`run_sql` records the change too, but without the task and session provenance,
and it does not return the policy verdict.

## What it does not do

- **No authentication.** The MCP server trusts whoever can run the process, the
  same as the `vdb` CLI. It is meant for a local agent runtime, not for exposing
  a database to the network.
- **No superuser by default.** `run_sql` connects as the non-superuser
  `vdbclient` role, so an agent cannot disable triggers or override the
  destructive-DDL guardrail. `VECTORADB_MCP_SUPERUSER=1` restores the old
  superuser behaviour (and `VECTORADB_AGENT_SUPERUSER=1` does the same for agent
  branches created over the HTTP API) — only for compatibility with setups that
  depended on it.
- **`branch_before_change` takes minutes, not seconds.** It restores a base
  backup and replays WAL, and it needs a base backup taken before the change
  (`vdb backup create`).

## See also

- `docs/policy-errors.md` — the machine-readable contract behind `policy_check`
  and blocked changes (`VDB01`, `VDB02`).
- `docs/ledger-anchor-format.md` — the anchor format `ledger_integrity` checks
  against, and what `vdb-verify` reads.
- The REST API (`GET /api/openapi.yaml` from a running engine) for the same
  operations over HTTP.
