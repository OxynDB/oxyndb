// SPDX-License-Identifier: AGPL-3.0-or-later

package branch

import (
	"strings"
	"testing"
)

func TestEntriesQuery(t *testing.T) {
	q := entriesQuery(5)
	for _, want := range []string{"'id', id", "ORDER BY id DESC LIMIT 5", "AT TIME ZONE 'UTC'"} {
		if !strings.Contains(q, want) {
			t.Errorf("query lost %q:\n%s", want, q)
		}
	}
}

func TestFormatLedgerEntries(t *testing.T) {
	if got := FormatLedgerEntries(nil); got != "No ledger entries." {
		t.Fatalf("empty = %q", got)
	}
	out := FormatLedgerEntries([]LedgerEntry{
		{ID: 612, At: "2026-09-14T10:00:00Z", Actor: "a@x.com", CommandTag: "CREATE TABLE", Object: "public.orders", Status: "APPLIED"},
		{ID: 611, At: "2026-09-14T09:59:00Z", Actor: "b@x.com", CommandTag: "DROP TABLE", Status: "BLOCKED", Risk: "drop"},
	})
	lines := strings.Split(out, "\n")
	if len(lines) != 3 || !strings.HasPrefix(lines[0], "ID") {
		t.Fatalf("table:\n%s", out)
	}
	// The id is the first column, so scripts can pick it out.
	if f := strings.Fields(lines[1]); f[0] != "612" {
		t.Fatalf("first column = %q", f[0])
	}
	if !strings.Contains(lines[2], "BLOCKED") || !strings.Contains(lines[2], "drop") {
		t.Fatalf("row: %q", lines[2])
	}
}
