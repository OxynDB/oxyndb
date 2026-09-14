// SPDX-License-Identifier: AGPL-3.0-or-later

package branch

import (
	"net/url"
	"testing"
)

func TestAgentDSN(t *testing.T) {
	got := agentDSN("agent-alice", "p@ss:w/rd", "10.0.0.5", "5432")
	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("agentDSN produced an unparsable URL %q: %v", got, err)
	}
	if u.Scheme != "postgresql" || u.Host != "10.0.0.5:5432" || u.Path != "/vectoradb" {
		t.Errorf("agentDSN = %q, want postgresql://…@10.0.0.5:5432/vectoradb", got)
	}
	if u.User.Username() != "agent-alice" {
		t.Errorf("user = %q, want agent-alice", u.User.Username())
	}
	if pw, _ := u.User.Password(); pw != "p@ss:w/rd" {
		t.Errorf("password = %q, want it round-tripped through escaping", pw)
	}

	// Never the superuser: the DSN carries the agent's own role.
	if u.User.Username() == pgUser {
		t.Errorf("agentDSN must not use the superuser %q", pgUser)
	}

	noPW, err := url.Parse(agentDSN("agent-bob", "", "h", "5432"))
	if err != nil {
		t.Fatal(err)
	}
	if _, set := noPW.User.Password(); set {
		t.Errorf("agentDSN with no password should omit it, got %q", noPW.String())
	}
}

func TestTruthyEnv(t *testing.T) {
	for _, tc := range []struct {
		val  string
		want bool
	}{
		{"", false}, {"0", false}, {"false", false}, {"no", false},
		{"1", true}, {"true", true}, {"TRUE", true}, {" yes ", true}, {"on", true},
	} {
		t.Setenv("VECTORADB_TEST_TRUTHY", tc.val)
		if got := truthyEnv("VECTORADB_TEST_TRUTHY"); got != tc.want {
			t.Errorf("truthyEnv(%q) = %v, want %v", tc.val, got, tc.want)
		}
	}
}

func TestSuperuserSwitchesDefaultOff(t *testing.T) {
	t.Setenv("VECTORADB_AGENT_SUPERUSER", "")
	t.Setenv("VECTORADB_MCP_SUPERUSER", "")
	if AgentSuperuser() || MCPSuperuser() {
		t.Error("superuser compatibility switches must be off by default")
	}
	t.Setenv("VECTORADB_AGENT_SUPERUSER", "1")
	t.Setenv("VECTORADB_MCP_SUPERUSER", "1")
	if !AgentSuperuser() || !MCPSuperuser() {
		t.Error("superuser compatibility switches should turn on with =1")
	}
}

func TestRandomPassword(t *testing.T) {
	a, err := randomPassword()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := randomPassword()
	if len(a) != 48 || a == b {
		t.Errorf("randomPassword: want 48 distinct hex chars, got %q and %q", a, b)
	}
}
