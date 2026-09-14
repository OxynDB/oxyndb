// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/vectoradb/vectoradb/internal/branch"
)

// ledgerV2Cmd handles the Schema Ledger 2.0 subcommands of `vdb ledger`:
//
//	vdb ledger checkpoint [branch]   anchor new entries outside the database
//	vdb ledger integrity [branch]    check the ledger against its anchors
//	vdb ledger export [branch]       every entry as JSON lines (--format jsonl)
//
// It returns false for anything else, leaving the existing subcommands untouched.
func ledgerV2Cmd(args []string) bool {
	if len(args) == 0 {
		return false
	}
	name := "main"
	if len(args) > 1 && !strings.HasPrefix(args[1], "-") {
		name = args[1]
	}
	switch args[0] {
	case "checkpoint":
		a, path, err := branch.Checkpoint(name)
		must(err)
		if a == nil {
			fmt.Printf("%s: nothing new to checkpoint\n", name)
			return true
		}
		fmt.Printf("checkpoint #%d on %s: ledger ids %d–%d (%d entries)\n", a.CheckpointID, name, a.FromID, a.ToID, a.EntryCount)
		fmt.Printf("  root   %s\n", a.MerkleRoot)
		fmt.Printf("  anchor %s\n", path)
	case "integrity":
		rep, err := branch.Integrity(name)
		must(err)
		fmt.Println(rep.Summary())
		if !rep.Intact {
			os.Exit(1)
		}
	case "export":
		if f := optValue(args, "--format"); f != "" && f != "jsonl" {
			must(fmt.Errorf("unsupported export format %q (supported: jsonl)", f))
		}
		must(branch.ExportLedger(name, os.Stdout))
	default:
		return false
	}
	return true
}
