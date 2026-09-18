# OxynDB — TypeScript client

A thin, dependency-free client for the OxynDB control-plane REST API (uses the
built-in `fetch`). Apache-2.0.

```ts
import { OxynDB } from "@oxyndb/client"

const db = new OxynDB("odb_…")            // API key
await db.createBranch("qa")
console.log(await db.query("qa", "select 1"))
console.log(await db.verifyBlackbox("qa"))   // tamper-evidence check (verifyLedger() still works)
```

> The engine serves a self-signed cert by default. In Node, point at a host with
> a real cert, or set `NODE_TLS_REJECT_UNAUTHORIZED=0` for local development only.

The full API is described by the OpenAPI spec at `GET /api/openapi.yaml`.
