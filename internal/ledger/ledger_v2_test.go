// SPDX-License-Identifier: AGPL-3.0-or-later

package ledger

import (
	"regexp"
	"strings"
	"testing"
)

// The 2.0 additions must stay additive: they may add objects next to the base
// ledger but never redefine or alter anything ledger.sql owns, or existing
// ledgers and hash chains could change underneath users.
func TestSchemaV2IsAdditive(t *testing.T) {
	if SchemaV2 == "" {
		t.Fatal("SchemaV2 is empty — is ledger_v2.sql embedded?")
	}
	forbidden := []*regexp.Regexp{
		regexp.MustCompile(`(?i)alter\s+table\s+(if\s+exists\s+)?vdb\.schema_ledger`),
		regexp.MustCompile(`(?i)alter\s+table\s+(if\s+exists\s+)?vdb\.policy`),
		regexp.MustCompile(`(?i)drop\s+(table|trigger|function|event\s+trigger)`),
		regexp.MustCompile(`(?i)function\s+vdb\.(_ledger_hash|chain_row|deny_change|guard_ddl_start|log_ddl_end|log_ddl_drop|_ctx|_skip|_may_override)\b`),
		regexp.MustCompile(`(?i)trigger\s+(vdb_chain|vdb_append_only|vdb_no_truncate)\b`),
		regexp.MustCompile(`(?i)event\s+trigger\s+vdb_(guard_start|log_end|log_drop)\b`),
	}
	for _, re := range forbidden {
		if loc := re.FindStringIndex(SchemaV2); loc != nil {
			t.Errorf("ledger_v2.sql touches a base-ledger object: %q", SchemaV2[loc[0]:loc[1]])
		}
	}
	// The base schema must not have picked up 2.0 objects either.
	if strings.Contains(Schema, "ledger_ext") {
		t.Error("ledger.sql references ledger_ext; 2.0 objects belong in ledger_v2.sql")
	}
}

// Every 2.0 trigger must be fail-safe and honour the kill switch, and the
// install must not leave replication-role changes behind.
func TestSchemaV2Safety(t *testing.T) {
	for _, want := range []string{
		"EXCEPTION WHEN OTHERS THEN",                   // capture errors become warnings
		"current_setting('vdb.v2', true), '') = 'off'", // kill switch
		"SET session_replication_role = replica;",      // install isn't recorded as user DDL
		"SET session_replication_role = DEFAULT;",      // …and is restored
		"REVOKE UPDATE, DELETE, TRUNCATE ON vdb.ledger_ext FROM PUBLIC;",
		"CREATE TABLE IF NOT EXISTS vdb.ledger_ext", // idempotent
	} {
		if !strings.Contains(SchemaV2, want) {
			t.Errorf("ledger_v2.sql is missing %q", want)
		}
	}
	if strings.Count(SchemaV2, "RETURNS trigger") != strings.Count(SchemaV2, "EXCEPTION WHEN OTHERS THEN")+1 {
		// capture_ext is fail-safe; deny_ext_change is the one trigger that must raise.
		t.Error("every 2.0 row trigger except the append-only guard must catch its own errors")
	}
}
