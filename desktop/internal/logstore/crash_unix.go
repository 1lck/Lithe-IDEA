//go:build !windows

package logstore

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// crashTempSuffix ends the hidden name a crash file has until it is locked.
const crashTempSuffix = ".tmp"

// createCrashFile creates and locks this session's crash file in dir. It is made under a hidden
// name, which is never claimed, and renamed only once locked, so no other process can claim it
// in between. The lock is an flock, which the descriptor the runtime duplicates shares and the
// kernel drops when the process ends, however it ends.
func createCrashFile(dir, session string) (*crashFile, error) {
	if session == "" {
		return nil, errors.New("logstore: the session has no name for its crash file")
	}
	temp := filepath.Join(dir, "."+session+crashTempSuffix)
	file, err := os.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	target := filepath.Join(dir, session)
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return nil, errors.Join(&os.PathError{Op: "flock", Path: temp, Err: err}, os.Remove(temp), file.Close())
	}
	if err := os.Rename(temp, target); err != nil {
		return nil, errors.Join(err, os.Remove(temp), file.Close())
	}
	return &crashFile{file: file, path: target}, nil
}

// claimCrashFile reads and removes the crash file at path when no running process holds it.
// claimed is false, without an error, when the file belongs to a running session or another
// starting process claimed it first.
func claimCrashFile(path string) (report []byte, claimed bool, err error) {
	file, err := os.OpenFile(path, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if errors.Is(err, fs.ErrNotExist) {
		// log-exempt: 预期的缺失：同时启动的进程刚认领并删除了它。
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	defer file.Close()
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		if errors.Is(err, unix.EWOULDBLOCK) {
			// log-exempt: 预期的缺失：文件属于仍在运行的会话。
			return nil, false, nil
		}
		return nil, false, &os.PathError{Op: "flock", Path: path, Err: err}
	}
	// Another process may have claimed and removed the file between the open and the lock.
	opened, err := file.Stat()
	if err != nil {
		return nil, false, err
	}
	current, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) || (err == nil && !os.SameFile(opened, current)) {
		// log-exempt: 预期的缺失：加锁之前同时启动的进程已认领并删除了它。
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if report, err = io.ReadAll(io.LimitReader(file, crashReadLimit)); err != nil {
		return nil, false, err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, false, err
	}
	return report, true, nil
}
