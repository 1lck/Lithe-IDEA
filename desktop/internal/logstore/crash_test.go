package logstore

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const crashedSession = "2026-11-08T09-00-00_0123abcd"
const killedSession = "2026-11-08T08-00-00_89abcdef"

// crashDir makes the crash directory of the log directory dir and returns it.
func crashDir(t *testing.T, dir string) string {
	t.Helper()
	crashes := filepath.Join(dir, crashDirName)
	if err := os.MkdirAll(crashes, 0o700); err != nil {
		t.Fatal(err)
	}
	return crashes
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}

func fileExists(t *testing.T, path string) bool {
	t.Helper()
	_, err := os.Lstat(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		t.Fatal(err)
	}
	return err == nil
}

// recordsOf lists the written records of event in the current session.
func recordsOf(t *testing.T, s *Store, event string) []core.LogRecord {
	t.Helper()
	var records []core.LogRecord
	for _, record := range window(t, s, Query{Session: "current"}).Records {
		if record.Event == event {
			records = append(records, record)
		}
	}
	return records
}

func TestEarlierSessionsThatDidNotCloseAreLogged(t *testing.T) {
	dir := t.TempDir()
	crashes := crashDir(t, dir)
	writeFile(t, filepath.Join(crashes, crashedSession), "panic: boom [recovered]\n\tpanic: boom\n\n"+
		"goroutine 1 [running]:\nmain.main()\n\t/src/cmd/lithe/main.go:9 +0x1c\n")
	writeFile(t, filepath.Join(crashes, killedSession), "")
	writeFile(t, filepath.Join(crashes, "notes.txt"), "not a crash file")

	s, _, _ := openStore(t, func(o *Options) { o.Dir = dir })
	s.CaptureCrashes()
	flush(t, s)

	crashed := recordsOf(t, s, "app.session.previous_interrupted")
	if len(crashed) != 1 || crashed[0].Fields["session"] != "sessions/"+crashedSession ||
		crashed[0].Fields["panic"] != "panic: boom [recovered]" || crashed[0].Fields["stack"] != "main.main main.go:9" {
		t.Fatalf("previous_interrupted = %+v", crashed)
	}
	killed := recordsOf(t, s, "app.session.close_missing")
	if len(killed) != 1 || killed[0].Fields["session"] != "sessions/"+killedSession {
		t.Fatalf("close_missing = %+v", killed)
	}
	if fileExists(t, filepath.Join(crashes, crashedSession)) || fileExists(t, filepath.Join(crashes, killedSession)) ||
		!fileExists(t, filepath.Join(crashes, "notes.txt")) {
		t.Fatal("the claimed files are not removed, or a file that is not a crash file is")
	}

	// This session's file exists while it runs; Clear Logs leaves it, and Close removes it.
	own := filepath.Join(crashes, sessionName(s.SessionPath()))
	if !fileExists(t, own) {
		t.Fatalf("this session's crash file %s is missing", own)
	}
	if err := s.ClearLogs(); err != nil {
		t.Fatalf("ClearLogs: %v", err)
	}
	if !fileExists(t, own) {
		t.Fatal("Clear Logs removed this session's crash file")
	}
	s.Close()
	if fileExists(t, own) {
		t.Fatal("Close left this session's crash file")
	}
}

func TestTheCrashFileOfARunningSessionIsNotClaimed(t *testing.T) {
	dir := t.TempDir()
	crashes := crashDir(t, dir)
	live, err := createCrashFile(crashes, crashedSession)
	if err != nil {
		t.Fatalf("createCrashFile: %v", err)
	}
	t.Cleanup(func() { _ = live.release() })

	s, _, _ := openStore(t, func(o *Options) { o.Dir = dir })
	s.CaptureCrashes()
	flush(t, s)
	if got := eventCounts(window(t, s, Query{Session: "current"}).Records); got["app.session.close_missing"] != 0 ||
		got["app.session.previous_interrupted"] != 0 || got["app.session.crash_capture_failed"] != 0 {
		t.Fatalf("records = %v, want the running session's file left alone", got)
	}
	if !fileExists(t, live.path) {
		t.Fatal("the running session's crash file was removed")
	}
}

func TestOneStartClaimsABoundedNumberOfCrashFiles(t *testing.T) {
	dir := t.TempDir()
	crashes := crashDir(t, dir)
	var names []string
	for i := range crashClaimLimit + 2 {
		name := fmt.Sprintf("2026-11-08T07-00-%02d_%08x", i, i)
		names = append(names, name)
		writeFile(t, filepath.Join(crashes, name), "")
	}
	slices.Sort(names)

	s, _, _ := openStore(t, func(o *Options) { o.Dir = dir })
	s.CaptureCrashes()
	flush(t, s)
	if got := len(recordsOf(t, s, "app.session.close_missing")); got != crashClaimLimit {
		t.Fatalf("close_missing records = %d, want %d", got, crashClaimLimit)
	}
	left := 0
	for _, name := range names {
		if fileExists(t, filepath.Join(crashes, name)) {
			left++
		}
	}
	if left != 2 {
		t.Fatalf("%d crash files are left, want 2 for the next start", left)
	}
}

func TestAFailedCrashCaptureIsLogged(t *testing.T) {
	dir := t.TempDir()
	// A file where the crash directory belongs.
	writeFile(t, filepath.Join(dir, crashDirName), "")

	s, _, _ := openStore(t, func(o *Options) { o.Dir = dir })
	s.CaptureCrashes()
	flush(t, s)
	failed := recordsOf(t, s, "app.session.crash_capture_failed")
	if len(failed) != 1 || failed[0].Fields["stage"] != "create" || failed[0].Fields["error_code"] == "" {
		t.Fatalf("crash_capture_failed = %+v", failed)
	}
}
