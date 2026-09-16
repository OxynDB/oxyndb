// SPDX-License-Identifier: AGPL-3.0-or-later

package controlplane

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The spec is the contract client generators read, and it drifted from the code
// once already (documented /api/import fields the handler never read, a 200 the
// handler never returns, filters that existed only in code). net/http's ServeMux
// cannot list what was registered, so this reads the route literals out of the
// three packages that serve HTTP and compares them with the spec's paths.
//
// It deliberately compares method+path only. Whether a body or response is
// described correctly is not something this can check — that part still relies
// on review.

var (
	// Any receiver, not just "mux": the agent routes are registered on an inner
	// mux that is then mounted behind the auth middleware.
	routeLiteral = regexp.MustCompile(`\b\w+\.(?:HandleFunc|Handle)\(\s*"([^"]+)"`)
	specPath     = regexp.MustCompile(`^  (/\S+):\s*$`)
	specMethod   = regexp.MustCompile(`^    (get|post|put|delete|patch):\s*$`)
)

// servedRoutes collects "METHOD /path" from the packages that register handlers.
func servedRoutes(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, pkg := range []string{".", "../auth", "../agentapi"} {
		entries, err := os.ReadDir(pkg)
		if err != nil {
			t.Fatalf("reading %s: %v", pkg, err)
		}
		for _, e := range entries {
			name := e.Name()
			if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
				continue
			}
			path := filepath.Join(pkg, name)
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("reading %s: %v", path, err)
			}
			for _, m := range routeLiteral.FindAllStringSubmatch(string(b), -1) {
				pattern := m[1]
				method, p, ok := strings.Cut(pattern, " ")
				// A pattern with no method is a subtree mount (the auth gates on
				// "/api/" and "/agents/", the SPA catch-all on "/"), not an
				// endpoint — the endpoints behind it are registered separately.
				if !ok || !strings.HasPrefix(p, "/") {
					continue
				}
				out[method+" "+p] = filepath.Base(path)
			}
		}
	}
	if len(out) < 20 {
		t.Fatalf("only found %d routes — the scan is broken, not the spec", len(out))
	}
	return out
}

// specRoutes collects "METHOD /path" from the embedded OpenAPI description.
func specRoutes(t *testing.T) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	path := ""
	for _, line := range strings.Split(string(openapiSpec), "\n") {
		if m := specPath.FindStringSubmatch(line); m != nil {
			path = m[1]
			continue
		}
		if m := specMethod.FindStringSubmatch(line); m != nil && path != "" {
			out[strings.ToUpper(m[1])+" "+path] = true
		}
	}
	if len(out) < 20 {
		t.Fatalf("only parsed %d operations from openapi.yaml — the parser is broken", len(out))
	}
	return out
}

// ledgerAlias maps a /blackbox path back to the /ledger path that serves it
// (blackboxAlias rewrites the request), so documenting both is not drift.
func ledgerAlias(route string) (string, bool) {
	if !strings.Contains(route, "/blackbox") {
		return "", false
	}
	return strings.Replace(route, "/blackbox", "/ledger", 1), true
}

func TestOpenAPIMatchesRoutes(t *testing.T) {
	served := servedRoutes(t)
	spec := specRoutes(t)

	var undocumented []string
	for route := range served {
		if spec[route] {
			continue
		}
		undocumented = append(undocumented, route+"  ("+served[route]+")")
	}
	sort.Strings(undocumented)
	if len(undocumented) > 0 {
		t.Errorf("served but missing from openapi.yaml:\n  %s", strings.Join(undocumented, "\n  "))
	}

	var phantom []string
	for route := range spec {
		if _, ok := served[route]; ok {
			continue
		}
		if alias, isAlias := ledgerAlias(route); isAlias {
			if _, ok := served[alias]; ok {
				continue // documented alias of a real route
			}
		}
		phantom = append(phantom, route)
	}
	sort.Strings(phantom)
	if len(phantom) > 0 {
		t.Errorf("in openapi.yaml but not served by any handler:\n  %s", strings.Join(phantom, "\n  "))
	}
}

// The /blackbox aliases are declared as path-item $refs rather than copies, so
// they cannot drift from the /ledger originals — but a pointer at a path that
// no longer exists would publish an endpoint resolving to nothing.
func TestOpenAPIAliasRefsResolve(t *testing.T) {
	declared := map[string]bool{}
	for _, line := range strings.Split(string(openapiSpec), "\n") {
		if m := specPath.FindStringSubmatch(line); m != nil {
			declared[m[1]] = true
		}
	}
	refs := regexp.MustCompile(`\$ref:\s*"#/paths/([^"]+)"`).FindAllStringSubmatch(string(openapiSpec), -1)
	if len(refs) == 0 {
		t.Fatal("no path aliases found — the /blackbox paths should alias the /ledger ones")
	}
	for _, m := range refs {
		target := strings.ReplaceAll(strings.ReplaceAll(m[1], "~1", "/"), "~0", "~")
		if !declared[target] {
			t.Errorf("alias $ref points at %s, which the spec does not declare", target)
		}
	}
}
