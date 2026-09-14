// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/vectoradb/vectoradb/internal/branch"
)

func argPresent(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func printJSON(v any) {
	b, err := json.MarshalIndent(v, "", "  ")
	must(err)
	fmt.Println(string(b))
}

// impactCmd: vdb impact "<SQL>" [--branch b] [--object o] [--column c] [--json]
//
// What a change would affect — the objects that depend on what it changes, the
// other branches that have it, the policy verdict and a score. Nothing is run.
func impactCmd(args []string) {
	sql := firstPositional(args, "--branch", "--object", "--column")
	object, column := optValue(args, "--object"), optValue(args, "--column")
	if sql == "" && object == "" {
		fmt.Println(`usage: vdb impact "<SQL>" [--branch <name>] [--object <table|view|index>] [--column <name>] [--json]`)
		os.Exit(2)
	}
	name := optValue(args, "--branch")
	if name == "" {
		name = "main"
	}
	rep, err := branch.Impact(name, sql, object, column)
	must(err)
	if argPresent(args, "--json") {
		printJSON(rep)
		return
	}
	fmt.Println(branch.FormatImpact(rep))
}

// diffCmd: vdb blackbox diff <a> <b> [--json], also vdb branch diff <a> <b>.
//
// The schema changes made on each branch since they split, from Blackbox.
func diffCmd(args []string) {
	var names []string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			names = append(names, a)
		}
	}
	if len(names) != 2 {
		fmt.Println("usage: vdb blackbox diff <branch-a> <branch-b> [--json]   (also: vdb branch diff)")
		os.Exit(2)
	}
	d, err := branch.DiffLedgers(names[0], names[1])
	must(err)
	if argPresent(args, "--json") {
		printJSON(d)
		return
	}
	fmt.Println(branch.FormatDiff(d))
}
