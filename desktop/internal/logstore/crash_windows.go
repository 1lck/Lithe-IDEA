//go:build windows

package logstore

import (
	"errors"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// crashTempSuffix ends the hidden name of a half-made crash file. Windows makes the file locked
// from the start, so it never has one; the name is shared with other platforms.
const crashTempSuffix = ".tmp"

// createCrashFile creates this session's crash file in dir. Its handle shares reading, writing
// and deletion, but every claim asks for exclusive access, so no other process can claim the
// file while this one, or the handle the runtime duplicates, keeps it open; Windows closes both
// when the process ends, however it ends.
func createCrashFile(dir, session string) (*crashFile, error) {
	if session == "" {
		return nil, errors.New("logstore: the session has no name for its crash file")
	}
	target := filepath.Join(dir, session)
	name, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return nil, &os.PathError{Op: "create", Path: target, Err: err}
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.CREATE_NEW, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, &os.PathError{Op: "create", Path: target, Err: err}
	}
	return &crashFile{file: os.NewFile(uintptr(handle), target), path: target}, nil
}

// claimCrashFile reads and removes the crash file at path when no running process holds it.
// claimed is false, without an error, when the file belongs to a running session, is being
// removed by the session that ended, or another starting process claimed it first.
func claimCrashFile(path string) (report []byte, claimed bool, err error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, false, &os.PathError{Op: "open", Path: path, Err: err}
	}
	// Exclusive access, and Windows deletes the file when this handle closes.
	handle, err := windows.CreateFile(name, windows.GENERIC_READ|windows.DELETE, 0, nil,
		windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_DELETE_ON_CLOSE, 0)
	switch {
	case errors.Is(err, windows.ERROR_FILE_NOT_FOUND), errors.Is(err, windows.ERROR_PATH_NOT_FOUND):
		// log-exempt: 预期的缺失：同时启动的进程刚认领并删除了它。
		return nil, false, nil
	case errors.Is(err, windows.ERROR_SHARING_VIOLATION), errors.Is(err, windows.ERROR_ACCESS_DENIED):
		// log-exempt: 预期的缺失：文件属于仍在运行的会话，或正被结束的会话删除。
		return nil, false, nil
	case err != nil:
		return nil, false, &os.PathError{Op: "open", Path: path, Err: err}
	}
	file := os.NewFile(uintptr(handle), path)
	report, err = io.ReadAll(io.LimitReader(file, crashReadLimit))
	if err = errors.Join(err, file.Close()); err != nil {
		return nil, false, err
	}
	return report, true, nil
}
