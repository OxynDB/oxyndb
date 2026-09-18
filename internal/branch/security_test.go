// SPDX-License-Identifier: AGPL-3.0-or-later

package branch

import (
	"testing"
)

func TestTruthyEnv(t *testing.T) {
	for _, tc := range []struct {
		val  string
		want bool
	}{
		{"", false}, {"0", false}, {"false", false}, {"no", false},
		{"1", true}, {"true", true}, {"TRUE", true}, {" yes ", true}, {"on", true},
	} {
		t.Setenv("OXYNDB_TEST_TRUTHY", tc.val)
		if got := truthyEnv("OXYNDB_TEST_TRUTHY"); got != tc.want {
			t.Errorf("truthyEnv(%q) = %v, want %v", tc.val, got, tc.want)
		}
	}
}

func TestSuperuserSwitchesDefaultOff(t *testing.T) {
	t.Setenv("OXYNDB_AGENT_SUPERUSER", "")
	t.Setenv("OXYNDB_MCP_SUPERUSER", "")
	if AgentSuperuser() || MCPSuperuser() {
		t.Error("superuser compatibility switches must be off by default")
	}
	t.Setenv("OXYNDB_AGENT_SUPERUSER", "1")
	t.Setenv("OXYNDB_MCP_SUPERUSER", "1")
	if !AgentSuperuser() || !MCPSuperuser() {
		t.Error("superuser compatibility switches should turn on with =1")
	}
}
