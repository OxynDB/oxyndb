// SPDX-License-Identifier: AGPL-3.0-or-later

package controlplane

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBlackboxToLedgerPath(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{"/api/branches/main/blackbox", "/api/branches/main/ledger", true},
		{"/api/branches/main/blackbox/verify", "/api/branches/main/ledger/verify", true},
		{"/api/branches/qa/blackbox/612/branch", "/api/branches/qa/ledger/612/branch", true},
		{"/api/branches/main/ledger/verify", "", false},
		{"/api/branches/blackbox/ledger", "", false}, // a branch named blackbox
		{"/api/branches//blackbox", "", false},
		{"/api/pipelines/blackbox", "", false},
		{"/api/branches/main/blackboxes", "", false},
	}
	for _, c := range cases {
		got, ok := blackboxToLedgerPath(c.in)
		if ok != c.ok || got != c.want {
			t.Errorf("blackboxToLedgerPath(%q) = %q, %v; want %q, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestBlackboxAlias(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/branches/{name}/ledger/verify", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "verify "+r.PathValue("name")+" "+r.URL.RawQuery)
	})
	mux.HandleFunc("GET /api/branches/{name}/ledger", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "list "+r.PathValue("name"))
	})
	h := blackboxAlias(mux)

	get := func(path string) (int, string) {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		return rec.Code, rec.Body.String()
	}
	for path, want := range map[string]string{
		"/api/branches/qa/blackbox/verify?x=1": "verify qa x=1",
		"/api/branches/qa/ledger/verify?x=1":   "verify qa x=1",
		"/api/branches/qa/blackbox":            "list qa",
		"/api/branches/qa/ledger":              "list qa",
	} {
		if code, body := get(path); code != 200 || body != want {
			t.Errorf("GET %s = %d %q; want 200 %q", path, code, body, want)
		}
	}
	if code, _ := get("/api/branches/qa/blackbox/nope"); code != 404 {
		t.Errorf("unknown alias path = %d; want 404", code)
	}
}
