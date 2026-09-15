// SPDX-License-Identifier: AGPL-3.0-or-later

package update

import (
	"bytes"
	"context"
	"fmt"
	"sort"
	"strings"
)

// Target is the platform being updated: the host OS and CPU, and the CPU of the
// Linux VM or distro the engine runs in (macOS; Windows is always amd64).
type Target struct {
	GOOS, HostArch, GuestArch string
}

// ImageContextAsset is the Postgres image build context Windows installs ship.
const ImageContextAsset = "vectoradb-docker-context.tar.gz"

// EngineAsset is the Linux engine binary: it runs in the VM (macOS), the WSL
// distro (Windows, always x86_64), or directly on a Linux host.
func EngineAsset(t Target) string {
	switch t.GOOS {
	case "windows":
		return "vdb-linux-amd64"
	case "darwin":
		if t.GuestArch != "" {
			return "vdb-linux-" + t.GuestArch
		}
	}
	return "vdb-linux-" + t.HostArch
}

// HostAsset is the `vdb` binary for the computer itself on macOS and Windows,
// or "" on Linux, where the engine binary is the host binary.
func HostAsset(t Target) string {
	switch t.GOOS {
	case "darwin":
		return "vdb-darwin-" + t.HostArch
	case "windows":
		return "vdb-windows-amd64.exe"
	}
	return ""
}

// RequiredAssets lists the release files an update of this platform needs. A
// release missing any of them (for example while it is still being published)
// is never offered.
func RequiredAssets(t Target) []string {
	var out []string
	if h := HostAsset(t); h != "" {
		out = append(out, h)
	}
	out = append(out, EngineAsset(t))
	if t.GOOS == "windows" {
		out = append(out, ImageContextAsset)
	}
	return out
}

// missingAssets returns the required files (and SHA256SUMS) a release lacks.
func missingAssets(r Release, required []string) []string {
	var missing []string
	for _, name := range append([]string{SumsAsset}, required...) {
		if _, ok := r.Asset(name); !ok {
			missing = append(missing, name)
		}
	}
	return missing
}

// Candidates returns the releases an update may install, newest first: newer
// than current, not a draft or prerelease, and with every file the target
// needs. A pinned tag ("v0.9.0") selects just that release; it may be a
// prerelease but must still be newer and complete.
func Candidates(rels []Release, current Version, t Target, pin string) ([]Release, error) {
	required := RequiredAssets(t)
	if pin != "" {
		want, err := ParseVersion(pin)
		if err != nil {
			return nil, err
		}
		for _, r := range rels {
			v, err := ParseVersion(r.Tag)
			if err != nil || v.Compare(want) != 0 || r.Draft {
				continue
			}
			if v.Compare(current) <= 0 {
				return nil, fmt.Errorf("%s is not newer than the installed %s — to go back to an older version, reinstall it with the installer (VDB_VERSION=%s)", r.Tag, current, r.Tag)
			}
			if m := missingAssets(r, required); len(m) > 0 {
				return nil, fmt.Errorf("release %s is missing %s", r.Tag, strings.Join(m, ", "))
			}
			return []Release{r}, nil
		}
		return nil, fmt.Errorf("no published release %s", pin)
	}

	type cand struct {
		r Release
		v Version
	}
	var cs []cand
	for _, r := range rels {
		if r.Draft || r.Prerelease {
			continue
		}
		v, err := ParseVersion(r.Tag)
		if err != nil || v.Compare(current) <= 0 {
			continue
		}
		if len(missingAssets(r, required)) > 0 {
			continue
		}
		cs = append(cs, cand{r, v})
	}
	sort.SliceStable(cs, func(i, j int) bool { return cs[i].v.Compare(cs[j].v) > 0 })
	out := make([]Release, len(cs))
	for i, c := range cs {
		out[i] = c.r
	}
	return out, nil
}

// Offer is a release ready to install, with its verified checksum list.
type Offer struct {
	Release  Release
	Version  Version
	Sums     Checksums
	Required []string
}

// Resolve finds the release to install: the newest candidate whose SHA256SUMS
// lists every file the target needs. It returns (nil, nil) when this install is
// already up to date.
func (c *Client) Resolve(ctx context.Context, current Version, t Target, pin string) (*Offer, error) {
	rels, err := c.ListReleases(ctx)
	if err != nil {
		return nil, err
	}
	cands, err := Candidates(rels, current, t, pin)
	if err != nil {
		return nil, err
	}
	required := RequiredAssets(t)
	var lastErr error
	for _, r := range cands {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		sa, _ := r.Asset(SumsAsset)
		body, err := c.fetchSmall(ctx, sa.URL, 1<<20)
		if err != nil {
			lastErr = err
			continue
		}
		sums, err := ParseChecksums(bytes.NewReader(body))
		if err != nil {
			lastErr = fmt.Errorf("%s: %w", r.Tag, err)
			continue
		}
		var unlisted []string
		for _, name := range required {
			if _, ok := sums[name]; !ok {
				unlisted = append(unlisted, name)
			}
		}
		if len(unlisted) > 0 {
			lastErr = fmt.Errorf("release %s: SHA256SUMS doesn't list %s", r.Tag, strings.Join(unlisted, ", "))
			continue
		}
		v, _ := ParseVersion(r.Tag)
		return &Offer{Release: r, Version: v, Sums: sums, Required: required}, nil
	}
	if pin != "" && lastErr != nil {
		return nil, lastErr
	}
	return nil, nil
}
