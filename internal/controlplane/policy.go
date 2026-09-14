// SPDX-License-Identifier: AGPL-3.0-or-later

package controlplane

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"

	"github.com/vectoradb/vectoradb/internal/auth"
	"github.com/vectoradb/vectoradb/internal/branch"
	"github.com/vectoradb/vectoradb/internal/ledger"
)

// registerPolicy mounts the Blackbox policy gate endpoints (behind auth). Reading
// and previewing are open to any signed-in user; changing rules needs vdb_admin
// on the branch.
//
//	GET    /api/branches/{name}/policies               rules
//	POST   /api/branches/{name}/policies               add a rule (admin)
//	PUT    /api/branches/{name}/policies/{rule}        change action / enabled (admin)
//	DELETE /api/branches/{name}/policies/{rule}        remove a custom rule (admin)
//	POST   /api/branches/{name}/policies/check         preview matches for a statement
//	GET    /api/branches/{name}/policies/evaluations   recent warnings, blocks, overrides
func registerPolicy(mux *http.ServeMux) {
	running := func(w http.ResponseWriter, name string) bool {
		if _, err := branch.EnsureRunning(name); err != nil {
			writeErr(w, 404, err)
			return false
		}
		return true
	}
	admin := func(w http.ResponseWriter, r *http.Request, name string) (string, bool) {
		u, _ := auth.UserFrom(r.Context())
		ok, err := branch.IsAdmin(name, u.Email)
		if err != nil {
			writeErr(w, 500, err)
			return "", false
		}
		if !ok {
			writeErr(w, 403, fmt.Errorf("changing Blackbox policy rules needs vdb_admin on %q — grant it with: vdb admin grant %s", name, u.Email))
			return "", false
		}
		return u.Email, true
	}
	fail := func(w http.ResponseWriter, err error) {
		switch {
		case errors.Is(err, branch.ErrInvalidRequest):
			writeErr(w, 400, err)
		case errors.Is(err, branch.ErrRuleNotFound):
			writeErr(w, 404, err)
		case errors.Is(err, branch.ErrRuleExists), errors.Is(err, branch.ErrBuiltinRule):
			writeErr(w, 409, err)
		default:
			writeErr(w, 500, err)
		}
	}

	mux.HandleFunc("GET /api/branches/{name}/policies", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if !running(w, name) {
			return
		}
		rules, err := branch.PolicyRules(name)
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, rules)
	})

	mux.HandleFunc("POST /api/branches/{name}/policies", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if !running(w, name) {
			return
		}
		email, ok := admin(w, r, name)
		if !ok {
			return
		}
		var rule branch.PolicyRule
		if err := json.NewDecoder(r.Body).Decode(&rule); err != nil {
			writeErr(w, 400, fmt.Errorf("invalid JSON: %w", err))
			return
		}
		if rule.Action == "" {
			rule.Action = "warn"
		}
		if err := branch.AddPolicyRule(name, rule, email); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 201, map[string]string{"rule_id": rule.RuleID, "status": "added"})
	})

	mux.HandleFunc("PUT /api/branches/{name}/policies/{rule}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if !running(w, name) {
			return
		}
		email, ok := admin(w, r, name)
		if !ok {
			return
		}
		var body struct {
			Action  *string `json:"action"`
			Enabled *bool   `json:"enabled"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeErr(w, 400, fmt.Errorf("invalid JSON: %w", err))
			return
		}
		if err := branch.UpdatePolicyRule(name, r.PathValue("rule"), body.Action, body.Enabled, email); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, map[string]string{"rule_id": r.PathValue("rule"), "status": "updated"})
	})

	mux.HandleFunc("DELETE /api/branches/{name}/policies/{rule}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if !running(w, name) {
			return
		}
		email, ok := admin(w, r, name)
		if !ok {
			return
		}
		if err := branch.RemovePolicyRule(name, r.PathValue("rule"), email); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, map[string]string{"rule_id": r.PathValue("rule"), "status": "removed"})
	})

	mux.HandleFunc("POST /api/branches/{name}/policies/check", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if !running(w, name) {
			return
		}
		var body struct {
			SQL string `json:"sql"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		tag, matches, err := branch.PolicyCheck(name, body.SQL)
		if err != nil {
			fail(w, err)
			return
		}
		if matches == nil {
			matches = []ledger.PolicyDetail{}
		}
		writeJSON(w, 200, map[string]any{"command": tag, "matches": matches})
	})

	mux.HandleFunc("GET /api/branches/{name}/policies/evaluations", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if !running(w, name) {
			return
		}
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		evs, err := branch.PolicyEvaluations(name, limit)
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, 200, evs)
	})
}
