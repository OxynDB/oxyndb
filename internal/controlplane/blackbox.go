// SPDX-License-Identifier: AGPL-3.0-or-later

package controlplane

import (
	"net/http"
	"strings"
)

// Blackbox is the product name for the record the code and database call the
// ledger. The REST routes keep the /ledger paths they shipped with; blackboxAlias
// also serves each of them with /blackbox in that place, so
// /api/branches/{name}/blackbox/verify reaches the same handler as
// /api/branches/{name}/ledger/verify. It sits inside the auth gate, so the alias
// is authenticated exactly like the original.
func blackboxAlias(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if p, ok := blackboxToLedgerPath(r.URL.Path); ok {
			r2 := r.Clone(r.Context())
			r2.URL.Path = p
			r2.URL.RawPath = ""
			next.ServeHTTP(w, r2)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// blackboxToLedgerPath maps /api/branches/{name}/blackbox[/…] to
// /api/branches/{name}/ledger[/…]. Any other path is left alone.
func blackboxToLedgerPath(p string) (string, bool) {
	parts := strings.SplitN(p, "/", 6) // "", "api", "branches", name, "blackbox", rest
	if len(parts) < 5 || parts[0] != "" || parts[1] != "api" || parts[2] != "branches" ||
		parts[3] == "" || parts[4] != "blackbox" {
		return "", false
	}
	parts[4] = "ledger"
	return strings.Join(parts, "/"), true
}
