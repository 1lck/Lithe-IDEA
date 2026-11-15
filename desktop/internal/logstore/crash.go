package logstore

import (
	"errors"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Crash capture.
//
// The Go runtime prints a fatal crash (a panic nobody recovers, a fatal error such as concurrent
// map writes) only to stderr, which a packaged application sends nowhere. CaptureCrashes also
// has the runtime write it to a file of this session, .crash/<session name> in the default log
// directory. That directory is the platform's writable per-user location the store already owns
// (see DefaultDir), never the application bundle or installation directory, so the file affects
// neither the code signature nor the base of a Sparkle delta update.
//
// The file is empty while the session runs, and Close removes it. A file an earlier process left
// behind is therefore either the crash report the runtime wrote, or empty because the process
// was killed, force quit or crashed outside the Go runtime; the next CaptureCrashes logs which,
// then removes the file. Only the process that created a file holds its lock, so the file of a
// session that is still running is never claimed. The directory is hidden, so log inventory,
// retention and Clear Logs leave it alone.
const (
	crashDirName = ".crash"
	// crashClaimLimit bounds the earlier files one start reads; the rest wait for the next one.
	crashClaimLimit = 8
	// crashReadLimit bounds the bytes read of one crash report. The crashing goroutine, the
	// only one the report keeps, comes first.
	crashReadLimit = 64 << 10
)

// crashFile is this session's crash file, open and locked for as long as the session runs.
type crashFile struct {
	file *os.File
	path string
}

// release removes the file, then closes it, so no other process can claim it in between.
func (c *crashFile) release() error {
	removeErr := os.Remove(c.path)
	return errors.Join(removeErr, c.file.Close())
}

// CaptureCrashes logs how earlier sessions that did not close their log ended, then has the Go
// runtime write a fatal crash of this process to this session's crash file. The runtime keeps a
// single crash output per process, so only the application's one store may capture; it must be
// called once, after Open. Failures are logged as app.session.crash_capture_failed; the
// application runs on without the capture.
func (s *Store) CaptureCrashes() {
	s.crashMu.Lock()
	defer s.crashMu.Unlock()
	s.mu.Lock()
	stopped := s.stopped
	s.mu.Unlock()
	if stopped || s.crash != nil || s.defaultDir == "" {
		return
	}
	dir := filepath.Join(s.defaultDir, crashDirName)
	if err := makeCrashDir(dir); err != nil {
		s.crashCaptureFailed("create", err)
		return
	}
	session := sessionName(s.SessionPath())
	// This session's file is locked before anything is claimed, so a process that starts at
	// the same time cannot take it for a leftover.
	own, err := createCrashFile(dir, session)
	if err != nil {
		s.crashCaptureFailed("create", err)
	}
	s.claimCrashes(dir, session)
	if own == nil {
		return
	}
	if err := debug.SetCrashOutput(own.file, debug.CrashOptions{}); err != nil {
		s.crashCaptureFailed("create", errors.Join(err, own.release()))
		return
	}
	s.crash = own
}

// releaseCrashFile stops the crash capture and removes this session's file. Close calls it
// before the store stops taking events, so a failure can still be logged.
func (s *Store) releaseCrashFile() {
	s.crashMu.Lock()
	defer s.crashMu.Unlock()
	own := s.crash
	s.crash = nil
	if own == nil {
		return
	}
	err := debug.SetCrashOutput(nil, debug.CrashOptions{})
	if err = errors.Join(err, own.release()); err != nil {
		s.crashCaptureFailed("release", err)
	}
}

// makeCrashDir creates the crash directory, private to the user, and refuses anything there
// that is not a directory, such as a symbolic link.
func makeCrashDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return &os.PathError{Op: "mkdir", Path: dir, Err: errors.New("not a directory")}
	}
	return nil
}

// claimCrashes logs and removes the crash files earlier processes left in dir, at most
// crashClaimLimit of them. own is this session's file, which is never claimed.
func (s *Store) claimCrashes(dir, own string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		s.crashCaptureFailed("claim", err)
		return
	}
	claimed := 0
	for _, entry := range entries {
		if claimed >= crashClaimLimit {
			return
		}
		name := entry.Name()
		stale := strings.HasPrefix(name, ".") && strings.HasSuffix(name, crashTempSuffix)
		if name == own || !entry.Type().IsRegular() || (!stale && !sessionNamePattern.MatchString(name)) {
			continue
		}
		report, ok, err := claimCrashFile(filepath.Join(dir, name))
		if err != nil {
			s.crashCaptureFailed("claim", err)
			continue
		}
		if !ok || stale {
			// log-exempt: 预期的缺失：文件属于仍在运行的会话、已被同时启动的进程认领，或是创建到一半的临时文件。
			continue
		}
		claimed++
		s.previousSessionEnded("sessions/"+name, report)
	}
}

// previousSessionEnded logs how the session whose crash file held report ended.
func (s *Store) previousSessionEnded(session string, report []byte) {
	headline := core.LogFirstLine(string(report))
	if headline == "" {
		s.Emit(core.LevelWarn, "app.session.close_missing", "", map[string]any{"session": session})
		return
	}
	fields := map[string]any{"session": session, "panic": headline}
	if frames := core.LogPanicStack(report); frames != "" {
		fields["stack"] = frames
	}
	s.Emit(core.LevelError, "app.session.previous_interrupted", "", fields)
}

func (s *Store) crashCaptureFailed(stage string, err error) {
	fields := core.LogErrorFields(err)
	fields["stage"] = stage
	s.Emit(core.LevelWarn, "app.session.crash_capture_failed", "", fields)
}
