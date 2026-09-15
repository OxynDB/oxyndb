// SPDX-License-Identifier: AGPL-3.0-or-later

package branch

import (
	"strings"
	"testing"
)

func TestSuspendRefusal(t *testing.T) {
	cases := []struct {
		name, primary string
		ha, refused   bool
	}{
		{"main", "vec-main", false, true},
		{"feature", "vec-main", true, false},
		{"standby", "vec-main", true, true},     // the HA standby
		{"standby", "vec-main", false, false},   // no HA: just a branch with that name
		{"standby", "vec-standby", true, true},  // serving main after a failover
		{"main", "vec-standby", true, true},     // the stepped-down old main
		{"feature", "vec-standby", true, false}, // ordinary branches stay suspendable
	}
	for _, c := range cases {
		err := suspendRefusal(c.name, c.primary, c.ha)
		if (err != nil) != c.refused {
			t.Errorf("suspendRefusal(%q, %q, ha=%v) = %v, want refused=%v", c.name, c.primary, c.ha, err, c.refused)
		}
	}
}

func TestHAGuard(t *testing.T) {
	for _, action := range []string{"enable", "disable", "failover"} {
		if err := haGuard(action, "vec-main"); err != nil {
			t.Errorf("%s with main as primary: %v", action, err)
		}
		err := haGuard(action, "vec-standby")
		if err == nil || !strings.Contains(err.Error(), "vdb ha failback") {
			t.Errorf("%s after a failover = %v, want a refusal pointing to failback", action, err)
		}
	}
	if err := haGuard("failback", "vec-main"); err == nil {
		t.Error("failback without a failover was allowed")
	}
	if err := haGuard("failback", "vec-standby"); err != nil {
		t.Errorf("failback after a failover: %v", err)
	}
}

func TestPrimaryPointerGuards(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if got := PrimaryContainer(); got != "vec-main" {
		t.Fatalf("fresh install primary = %q", got)
	}
	if err := setPrimary("standby"); err != nil {
		t.Fatal(err)
	}
	if got := PrimaryContainer(); got != "vec-standby" {
		t.Fatalf("after failover primary = %q", got)
	}
	if haGuard("disable", PrimaryContainer()) == nil || suspendRefusal("standby", PrimaryContainer(), true) == nil {
		t.Fatal("the promoted standby isn't protected")
	}
	if err := setPrimary("main"); err != nil {
		t.Fatal(err)
	}
	if haGuard("enable", PrimaryContainer()) != nil {
		t.Fatal("enable refused after failback")
	}
}

func TestLSNAtLeast(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"0/3000028", "0/3000028", true},
		{"1/0", "0/FFFFFFFF", true},
		{"0/2FFFFFF", "0/3000000", false},
		{" 16/B374D848\n", "16/B374D847", true},
		{"", "0/1", false},
		{"bad", "0/1", false},
		{"0/1", "zz/1", false},
	}
	for _, c := range cases {
		if got := lsnAtLeast(c.a, c.b); got != c.want {
			t.Errorf("lsnAtLeast(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestParseControlCheckpoint(t *testing.T) {
	out := `pg_control version number:            1300
Database cluster state:               shut down
Latest checkpoint location:           0/5000060
Latest checkpoint's REDO location:    0/5000028
`
	got, err := parseControlCheckpoint(out)
	if err != nil || got != "0/5000060" {
		t.Fatalf("parseControlCheckpoint = %q, %v", got, err)
	}
	if _, err := parseControlCheckpoint("Latest checkpoint's REDO location: 0/1\n"); err == nil {
		t.Fatal("accepted output without the checkpoint location")
	}
}
