//go:build windows

// SPDX-License-Identifier: AGPL-3.0-or-later

package host

import (
	"os"

	"golang.org/x/sys/windows"
)

// Setup's closing summary is the one line a first-time user looks for, so it is
// printed in green — as the installer's own line used to be, before the engine
// took over printing the summary.
//
// Go does not turn on the console's escape-sequence handling, so a raw colour
// code can print as literal junk on an older conhost. enableVT asks for it once;
// if the console refuses, or output is being piped to a file, the text is left
// plain rather than risking `←[32m` in someone's log.
var vtEnabled = enableVT()

func enableVT() bool {
	h := windows.Handle(os.Stdout.Fd())
	var mode uint32
	if err := windows.GetConsoleMode(h, &mode); err != nil {
		return false // not a console (piped or redirected)
	}
	if mode&windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0 {
		return true
	}
	return windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == nil
}

// green wraps s in the ANSI green sequence when the console can render it.
func green(s string) string { return colorize(s, vtEnabled) }

// colorize is the decision on its own, so it can be tested without a console.
func colorize(s string, enabled bool) string {
	if !enabled {
		return s
	}
	return "\033[32m" + s + "\033[0m"
}
