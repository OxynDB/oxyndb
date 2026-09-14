// SPDX-License-Identifier: AGPL-3.0-or-later

package mcp

import (
	"strings"
	"testing"
)

func TestBlackboxToolAliases(t *testing.T) {
	byName := map[string]map[string]any{}
	for _, tl := range toolList() {
		byName[tl["name"].(string)] = tl
	}
	for _, a := range blackboxToolNames {
		orig, ok := byName[a.ledger]
		if !ok {
			t.Fatalf("original tool %q is no longer listed", a.ledger)
		}
		alias, ok := byName[a.blackbox]
		if !ok {
			t.Fatalf("Blackbox tool %q is not listed", a.blackbox)
		}
		if resolveTool(a.blackbox) != a.ledger || resolveTool(a.ledger) != a.ledger {
			t.Errorf("resolveTool does not map %q to %q", a.blackbox, a.ledger)
		}
		if !strings.Contains(alias["description"].(string), "Same as "+a.ledger) {
			t.Errorf("%q description doesn't name its original", a.blackbox)
		}
		if alias["inputSchema"] == nil || orig["inputSchema"] == nil {
			t.Errorf("%q lost its input schema", a.blackbox)
		}
	}
	for _, name := range []string{"create_branch", "run_sql", "changes", "branch_before_change"} {
		if resolveTool(name) != name {
			t.Errorf("resolveTool changed %q", name)
		}
	}
	if len(byName) != len(toolList()) {
		t.Error("duplicate tool names")
	}
}
