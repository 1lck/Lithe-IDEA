package toolchain

import (
	"errors"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

// Note: .agents/notes/implemented/bug-fix/2026-11-19-windows-toolchain-junction-paths.md
// Go's EvalSymlinks walks symbolic links but does not resolve Windows directory
// junctions. Ask the filesystem for the final path of the opened target.
func resolveNativePath(absolute string) (resolved string, err error) {
	native := absolute
	if !strings.HasPrefix(native, `\\?\`) {
		if tail, unc := strings.CutPrefix(native, `\\`); unc {
			native = `\\?\UNC\` + tail
		} else {
			native = `\\?\` + native
		}
	}
	name, err := windows.UTF16PtrFromString(native)
	if err != nil {
		return "", err
	}
	handle, err := windows.CreateFile(name, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return "", err
	}
	defer func() {
		if closeErr := windows.CloseHandle(handle); closeErr != nil {
			err = errors.Join(err, closeErr)
		}
	}()

	var initial [windows.MAX_PATH]uint16
	buffer := initial[:]
	for {
		// Zero requests FILE_NAME_NORMALIZED and VOLUME_NAME_DOS.
		length, err := windows.GetFinalPathNameByHandle(handle, &buffer[0], uint32(len(buffer)), 0)
		if err != nil {
			return "", err
		}
		if length >= uint32(len(buffer)) {
			buffer = make([]uint16, length+1)
			continue
		}
		path := windows.UTF16ToString(buffer[:length])
		if share, ok := strings.CutPrefix(path, `\\?\UNC\`); ok {
			return `\\` + share, nil
		}
		path = strings.TrimPrefix(path, `\\?\`)
		if filepath.IsAbs(path) && len(filepath.VolumeName(path)) == 2 {
			return path, nil
		}
		return "", windows.ERROR_BAD_PATHNAME
	}
}
