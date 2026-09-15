// SPDX-License-Identifier: AGPL-3.0-or-later

package update

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

// EnvNoCheck turns off the check `vdb start` makes for a newer release.
const EnvNoCheck = "VECTORADB_NO_UPDATE_CHECK"

func truthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// ShouldCheck reports whether `vdb start` should look for a newer release: not
// when turned off, and not for development builds.
func ShouldCheck(getenv func(string) string, current string) bool {
	if truthy(getenv(EnvNoCheck)) {
		return false
	}
	v, err := ParseVersion(current)
	return err == nil && !v.IsDev()
}

// CheckTimeout is how long `vdb start` waits for the check
// (VECTORADB_UPDATE_CHECK_TIMEOUT, default 1.5s).
func CheckTimeout(getenv func(string) string) time.Duration {
	if d, err := time.ParseDuration(strings.TrimSpace(getenv("VECTORADB_UPDATE_CHECK_TIMEOUT"))); err == nil && d > 0 {
		return d
	}
	return 1500 * time.Millisecond
}

// Notice is the one line `vdb start` prints when a newer release is available.
func Notice(current string, o *Offer) string {
	return fmt.Sprintf("VectoraDB %s is available (you have %s). Run `vdb update` to get the new capabilities.", o.Release.Tag, current)
}

// BackgroundCheck starts looking for a newer release and returns a function
// that yields the notice — or "" when there is none, the check failed (offline,
// rate limited) or it didn't finish within the timeout. It never blocks longer
// than the timeout, counted from when the check started.
func BackgroundCheck(c *Client, current string, t Target, timeout time.Duration) func() string {
	cur, err := ParseVersion(current)
	if err != nil {
		return func() string { return "" }
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	ch := make(chan string, 1)
	go func() {
		o, err := c.Resolve(ctx, cur, t, "")
		if err != nil || o == nil {
			ch <- ""
			return
		}
		ch <- Notice(current, o)
	}()
	return func() string {
		defer cancel()
		select {
		case s := <-ch:
			return s
		case <-ctx.Done():
			select {
			case s := <-ch:
				return s
			default:
				return ""
			}
		}
	}
}

// IsTerminal reports whether f is an interactive terminal.
func IsTerminal(f *os.File) bool {
	if f == nil {
		return false
	}
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}
