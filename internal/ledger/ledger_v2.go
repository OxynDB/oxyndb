// SPDX-License-Identifier: AGPL-3.0-or-later

package ledger

import _ "embed"

// SchemaV2 is the idempotent SQL for the Blackbox 2.0 additions. Apply it
// after Schema, with a superuser connection to the target branch. It never
// alters an object Schema owns, so existing ledgers and hash chains are untouched.
//
//go:embed ledger_v2.sql
var SchemaV2 string
