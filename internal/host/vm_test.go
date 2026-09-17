// SPDX-License-Identifier: AGPL-3.0-or-later

package host

import "testing"

func TestVMSubcommand(t *testing.T) {
	for _, c := range []struct {
		args    []string
		want    string
		wantErr bool
	}{
		{nil, "status", false},
		{[]string{"status"}, "status", false},
		{[]string{"shell"}, "shell", false},
		{[]string{"--help"}, "help", false},
		{[]string{"shell", "extra"}, "", true},
		{[]string{"reboot"}, "", true},
	} {
		got, err := vmSubcommand(c.args)
		if got != c.want || (err != nil) != c.wantErr {
			t.Errorf("vmSubcommand(%q) = %q, %v; want %q, error %v", c.args, got, err, c.want, c.wantErr)
		}
	}
	if gib(4294967296) != "4 GiB" {
		t.Errorf("gib(4 GiB) = %q", gib(4294967296))
	}
}
