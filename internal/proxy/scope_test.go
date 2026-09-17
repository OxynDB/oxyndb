// SPDX-License-Identifier: AGPL-3.0-or-later

package proxy

import "testing"

// A branch-scoped key is an agent's only credential, so the check that confines
// it to its own branch is the whole of that confinement.
func TestScopeAllows(t *testing.T) {
	cases := []struct {
		scope, target string
		want          bool
		why           string
	}{
		{"", "main", true, "an account key opens any branch"},
		{"", "agent-alice", true, "an account key opens an agent branch too"},
		{"agent-alice", "agent-alice", true, "a scoped key opens its own branch"},
		{"agent-alice", "main", false, "a scoped key must not reach main"},
		{"agent-alice", "agent-bob", false, "a scoped key must not reach another agent"},
		{"agent-alice", "", false, "an empty target must not pass the scope check"},
		{"agent-alice", "agent-alice2", false, "prefix matches are not the same branch"},
	}
	for _, c := range cases {
		if got := scopeAllows(c.scope, c.target); got != c.want {
			t.Errorf("scopeAllows(%q, %q) = %v, want %v — %s", c.scope, c.target, got, c.want, c.why)
		}
	}
}
