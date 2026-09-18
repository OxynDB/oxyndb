//go:build windows

// SPDX-License-Identifier: AGPL-3.0-or-later

package host

import "fmt"

func vmStatus() error {
	if !wslInstalled() {
		fmt.Println("WSL isn't installed, so there is no OxynDB VM yet — run the installer or `odb setup`.")
		return nil
	}
	name := currentDistro()
	if !distroExists(name) {
		fmt.Printf("No OxynDB VM yet (WSL distro %q) — run `odb setup` to create it.\n", name)
		return nil
	}
	state := "Stopped"
	if distroRunning(name) {
		state = "Running"
	}
	fmt.Printf("OxynDB VM: %s (WSL2 distro)\n  status  %s\n", name, state)
	if state != "Running" {
		fmt.Println("Start it, and the stack inside it, with: odb start")
	}
	return nil
}

func vmShell() error {
	if !wslInstalled() {
		return fmt.Errorf("WSL is required on Windows — run the installer or `odb setup`")
	}
	name := currentDistro()
	if !distroExists(name) {
		return fmt.Errorf("no OxynDB VM yet — run `odb setup` once to create it")
	}
	return wsl("-d", name).Run()
}
