// SPDX-License-Identifier: AGPL-3.0-or-later

package controlplane

import (
	"net/http"

	"github.com/vectoradb/vectoradb/internal/branch"
)

// registerLedgerV2 mounts the Schema Ledger 2.0 endpoints (behind auth):
//
//	GET  /api/branches/{name}/ledger/integrity   check the ledger against its anchors
//	POST /api/branches/{name}/ledger/checkpoint  anchor new entries now
//	GET  /api/branches/{name}/ledger/export      every entry as JSON lines
func registerLedgerV2(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/branches/{name}/ledger/integrity", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if _, err := branch.EnsureRunning(name); err != nil {
			writeErr(w, 404, err)
			return
		}
		rep, err := branch.Integrity(name)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		writeJSON(w, 200, rep)
	})

	mux.HandleFunc("POST /api/branches/{name}/ledger/checkpoint", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if _, err := branch.EnsureRunning(name); err != nil {
			writeErr(w, 404, err)
			return
		}
		a, path, err := branch.Checkpoint(name)
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		if a == nil {
			writeJSON(w, 200, map[string]any{"checkpoint": nil, "status": "nothing new"})
			return
		}
		writeJSON(w, 201, map[string]any{"checkpoint": a, "anchor_path": path, "status": "created"})
	})

	mux.HandleFunc("GET /api/branches/{name}/ledger/export", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if _, err := branch.EnsureRunning(name); err != nil {
			writeErr(w, 404, err)
			return
		}
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.Header().Set("Content-Disposition", `attachment; filename="`+name+`-ledger.jsonl"`)
		if err := branch.ExportLedger(name, w); err != nil {
			// Headers may be out already; the truncated body plus the log is all we can do.
			http.Error(w, err.Error(), 500)
		}
	})
}
