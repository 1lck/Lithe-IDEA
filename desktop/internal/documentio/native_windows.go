//go:build windows

package documentio

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

func openDocument(path string) (*os.File, os.FileInfo, fileIdentity, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, nil, fileIdentity{}, err
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, nil, fileIdentity{}, &os.PathError{Op: "open", Path: path, Err: err}
	}
	file := os.NewFile(uintptr(handle), path)
	var native windows.ByHandleFileInformation
	if err = windows.GetFileInformationByHandle(handle, &native); err != nil {
		file.Close()
		return nil, nil, fileIdentity{}, err
	}
	if native.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		file.Close()
		return nil, nil, fileIdentity{}, ErrSymbolicLink
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, fileIdentity{}, err
	}
	if !info.Mode().IsRegular() {
		file.Close()
		return nil, nil, fileIdentity{}, ErrNotRegular
	}
	identity := fileIdentity{
		links: uint64(native.NumberOfLinks),
		id:    fmt.Sprintf("%x:%x:%x", native.VolumeSerialNumber, native.FileIndexHigh, native.FileIndexLow),
	}
	return file, info, identity, nil
}

// ReplaceFileW preserves the replaced file's ACL and other supported metadata.
func copyMetadata(*os.File, *os.File, os.FileInfo) error { return nil }

var replaceFileW = windows.NewLazySystemDLL("kernel32.dll").NewProc("ReplaceFileW")

func replaceDocument(stage, target string) error {
	from, err := windows.UTF16PtrFromString(stage)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return err
	}
	result, _, callErr := replaceFileW.Call(uintptr(unsafe.Pointer(to)), uintptr(unsafe.Pointer(from)), 0, 0, 0, 0)
	if result == 0 {
		if callErr == syscall.Errno(0) {
			return syscall.EINVAL
		}
		return callErr
	}
	return nil
}

// MoveFileEx without MOVEFILE_REPLACE_EXISTING atomically refuses an existing target.
func installMissingDocument(stage, target string) error {
	from, err := windows.UTF16PtrFromString(stage)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(target)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(from, to, 0)
}
