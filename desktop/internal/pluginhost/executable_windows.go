package pluginhost

import (
	"errors"
	"os"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Note: .agents/notes/implemented/bug-fix/2026-11-09-viva-windows-native-file-validation.md
var getBinaryType = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetBinaryTypeW")

// Windows has no Unix execute bits. Ask the native image loader to identify a
// Win32/Win64 executable, including images without an extension; never run it.
// See https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-getbinarytypew.
func verifyNativeExecutable(path string, _ os.FileInfo) error {
	// The package resolver already supplied an absolute native path. Preserve
	// long drive and UNC paths when passing it to this Win32 API.
	if !strings.HasPrefix(path, `\\?\`) {
		if strings.HasPrefix(path, `\\`) {
			path = `\\?\UNC\` + path[2:]
		} else {
			path = `\\?\` + path
		}
	}
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return errors.Join(ErrNotExecutable, err)
	}
	var kind uint32
	// Both pointers are borrowed only for this synchronous native call.
	ok, _, callErr := getBinaryType.Call(uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&kind)))
	runtime.KeepAlive(name)
	if ok == 0 {
		if callErr != nil && callErr != windows.ERROR_SUCCESS {
			return errors.Join(ErrNotExecutable, callErr)
		}
		return ErrNotExecutable
	}
	const (
		binaryWin32 = 0
		binaryWin64 = 6
	)
	if kind != binaryWin32 && kind != binaryWin64 {
		return ErrNotExecutable
	}
	return nil
}
