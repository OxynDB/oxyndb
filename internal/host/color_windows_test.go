//go:build windows

// SPDX-License-Identifier: AGPL-3.0-or-later

package host

import "testing"

func TestColorize(t *testing.T) {
	if got := colorize("VectoraDB is running.", true); got != "\033[32mVectoraDB is running.\033[0m" {
		t.Errorf("colorize(enabled) = %q", got)
	}
	// Piped or redirected output must stay plain: escape codes in install.log
	// are noise, and an older console prints them literally.
	if got := colorize("VectoraDB is running.", false); got != "VectoraDB is running." {
		t.Errorf("colorize(disabled) = %q, want the text unchanged", got)
	}
}
