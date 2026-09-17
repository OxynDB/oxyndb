// SPDX-License-Identifier: AGPL-3.0-or-later

package branch

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func at(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

func backupAt(name, finish, sysID string) walgBackup {
	return walgBackup{Name: name, FinishTime: at(finish), SystemID: json.Number(sysID)}
}

// A restore has to start from a base backup that finished before the point
// asked for; fetching LATEST made an earlier target unreachable.
func TestPickBackupForTime(t *testing.T) {
	bs := []walgBackup{
		backupAt("base_00000001000000000000001A", "2026-09-01T10:00:00Z", "77"),
		backupAt("base_00000001000000000000002E", "2026-09-10T10:00:00Z", "77"),
		backupAt("base_000000010000000000000042", "2026-09-15T10:00:00Z", "77"),
		backupAt("base_000000010000000000000099", "2026-09-05T10:00:00Z", "12"), // another database
		backupAt("not-a-backup", "2026-09-14T10:00:00Z", "77"),
	}
	cases := []struct {
		target string
		want   string
	}{
		{"2026-09-16T00:00:00Z", "base_000000010000000000000042"}, // newest overall
		{"2026-09-12T00:00:00Z", "base_00000001000000000000002E"}, // not the newest: the one before the target
		{"2026-09-02T00:00:00Z", "base_00000001000000000000001A"}, // oldest
		{"2026-09-10T10:00:00Z", "base_00000001000000000000002E"}, // a backup that finished exactly at the target
	}
	for _, c := range cases {
		got, err := pickBackupForTime(bs, "77", at(c.target))
		if err != nil {
			t.Fatalf("%s: %v", c.target, err)
		}
		if got.Name != c.want {
			t.Errorf("target %s: chose %s, want %s", c.target, got.Name, c.want)
		}
	}

	// Nothing precedes the target: refused, naming what the archive does reach,
	// rather than silently restoring from a later backup.
	_, err := pickBackupForTime(bs, "77", at("2026-08-01T00:00:00Z"))
	if !errors.Is(err, ErrNoBaseBackup) {
		t.Fatalf("expected ErrNoBaseBackup, got %v", err)
	}
	if !strings.Contains(err.Error(), "2026-09-01T10:00:00Z") {
		t.Errorf("refusal should name the oldest backup: %v", err)
	}

	// A backup of an earlier database with the same bucket is never chosen.
	if _, err := pickBackupForTime(bs, "12", at("2026-09-16T00:00:00Z")); err != nil {
		t.Fatalf("system id 12: %v", err)
	} else if got, _ := pickBackupForTime(bs, "12", at("2026-09-16T00:00:00Z")); got.Name != "base_000000010000000000000099" {
		t.Errorf("system id 12: chose %s", got.Name)
	}
}

func TestParseRestoreTime(t *testing.T) {
	want := at("2026-09-16T18:30:00Z")
	for _, s := range []string{
		"2026-09-16 18:30:00+00",
		"2026-09-16 18:30:00.000000+00",
		"2026-09-16T18:30:00Z",
		"2026-09-16 18:30:00",
		"2026-09-16 18:30",
		"  2026-09-16T18:30:00Z  ",
	} {
		got, ok := parseRestoreTime(s)
		if !ok || !got.Equal(want) {
			t.Errorf("%q -> %v, %v; want %v", s, got, ok, want)
		}
	}
	// An offset is honoured rather than assumed to be UTC.
	if got, ok := parseRestoreTime("2026-09-16 20:30:00+02"); !ok || !got.Equal(want) {
		t.Errorf("+02 offset -> %v, %v; want %v", got, ok, want)
	}
	// Unreadable here: the caller keeps the old behaviour instead of refusing.
	for _, s := range []string{"latest", "yesterday", "16/09/2026", ""} {
		if _, ok := parseRestoreTime(s); ok {
			t.Errorf("%q should not parse", s)
		}
	}
}

// The restore script must use the backup the caller chose, and must still
// handle "latest" the way it always did.
func TestRestorePITRScript(t *testing.T) {
	for _, want := range []string{
		`: "${BACKUP_NAME:=LATEST}"`,
		`wal-g backup-fetch "$PGDATA" "$BACKUP_NAME"`,
		"recovery_target_time = '$RECOVERY_TARGET_TIME'",
		"recovery_target_action = 'promote'",
		"archive_mode = off",
	} {
		if !strings.Contains(restorePITRScript, want) {
			t.Errorf("restore script is missing %q", want)
		}
	}
	if strings.Contains(restorePITRScript, `backup-fetch "$PGDATA" LATEST`) {
		t.Error("restore script must fetch the chosen backup, not LATEST unconditionally")
	}
}
