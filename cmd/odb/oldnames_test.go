// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The product was renamed to OxynDB (command odb) before it was ever published,
// everywhere at once: brand, command, environment variables, the SQL schema and
// roles, error codes, the API-key prefix, container and storage names. A stray
// old name would be a real defect, not a cosmetic one — a script still calling
// the old command, a query against the old schema, a key checked against the
// old prefix — so the repository is kept free of them.
//
// A line may keep an old name only to record history, and must then say
// "renamed from" (the change log does).
func TestNoOldProductNames(t *testing.T) {
	// Built from parts so this file does not match itself.
	old := regexp.MustCompile(strings.Join([]string{
		`[Vv]ector` + `a`, // the old brand, any casing of what follows
		`VECTOR` + `ADB`,
		`(^|[^A-Za-z0-9])(v` + `db|V` + `DB|V` + `db)`, // the old command and its prefixes
		`(^|[^A-Za-z0-9_])v` + `ec-`,                   // the old container prefix
	}, "|"))

	root := filepath.Join("..", "..")
	skipDir := map[string]bool{".git": true, "node_modules": true, "dist": true, "bin": true, ".claude": true}
	binary := regexp.MustCompile(`\.(pdf|png|jpe?g|webp|ico|gif|woff2?|ttf|exe|tar|gz|zip)$`)
	self, _ := filepath.Abs("oldnames_test.go")

	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if skipDir[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		// go.sum and the npm lock file hold base64 hashes, where any three
		// letters can appear by chance.
		if binary.MatchString(path) || d.Name() == "go.sum" || d.Name() == "package-lock.json" {
			return nil
		}
		if abs, _ := filepath.Abs(path); abs == self {
			return nil
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1024*1024), 16*1024*1024) // the living docs have long lines
		for n := 1; sc.Scan(); n++ {
			line := sc.Text()
			if old.MatchString(line) && !strings.Contains(strings.ToLower(line), "renamed from") {
				rel, _ := filepath.Rel(root, path)
				t.Errorf("%s:%d still uses an old product name: %s", rel, n, strings.TrimSpace(truncate(line, 160)))
			}
		}
		return sc.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
