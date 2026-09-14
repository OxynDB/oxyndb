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
		"IF vdb._capture_disabled() THEN",              // …checked inside the fail-safe block
		"s.setrole = 0",                                // …honoured database-wide
		"rolname = session_user",                       // …or in a superuser's own session
		"SET session_replication_role = replica;",      // install isn't recorded as user DDL
		"SET session_replication_role = DEFAULT;",      // …and is restored
		"REVOKE UPDATE, DELETE, TRUNCATE ON vdb.ledger_ext FROM PUBLIC;",
		"CREATE TABLE IF NOT EXISTS vdb.ledger_ext", // idempotent
		"CREATE TABLE IF NOT EXISTS vdb.ledger_checkpoints",
		"REVOKE UPDATE, DELETE, TRUNCATE ON vdb.ledger_checkpoints FROM PUBLIC;",
	} {
		if !strings.Contains(SchemaV2, want) {
			t.Errorf("ledger_v2.sql is missing %q", want)
		}
	}
	// Guards whose job is to refuse a write must raise; every other 2.0 trigger
	// must catch its own errors.
	const raisingGuards = 2 // deny_ext_change (append-only), checkpoint_contiguous
	if strings.Count(SchemaV2, "RETURNS trigger") != strings.Count(SchemaV2, "EXCEPTION WHEN OTHERS THEN")+raisingGuards {
		t.Error("every 2.0 trigger except the raising guards must catch its own errors")
	}
}

// A client's own SET vdb.v2 = 'off' must not skip capture: the switch is read
// only through vdb._capture_disabled, never directly by a trigger.
func TestCaptureKillSwitchNotClientSettable(t *testing.T) {
	fn := strings.Index(SchemaV2, "CREATE OR REPLACE FUNCTION vdb._capture_disabled()")
	body := strings.Index(SchemaV2, "CREATE OR REPLACE FUNCTION vdb.capture_ext()")
	if fn < 0 || body < 0 || fn > body {
		t.Fatal("vdb._capture_disabled must be defined before capture_ext")
	}
	if strings.Count(SchemaV2, "current_setting('vdb.v2'") != 1 {
		t.Error("vdb.v2 must be read in exactly one place, vdb._capture_disabled")
	}
	disabled := SchemaV2[fn:body]
	for _, want := range []string{"pg_db_role_setting", "s.setrole = 0", "c.cfg = 'vdb.v2=off'", "rolsuper", "SECURITY DEFINER"} {
		if !strings.Contains(disabled, want) {
			t.Errorf("vdb._capture_disabled is missing %q", want)
		}
	}
}
