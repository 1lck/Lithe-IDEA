//go:build windows

package documentio

import (
	"errors"
	"golang.org/x/sys/windows"
	"os"
)

func openReadable(path string) (*os.File, os.FileInfo, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, nil, err
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	file := os.NewFile(uintptr(handle), path)
	kind, err := windows.GetFileType(handle)
	if err != nil {
		return nil, nil, errors.Join(err, file.Close())
	}
	if kind != windows.FILE_TYPE_DISK {
		return nil, nil, errors.Join(ErrNotRegular, file.Close())
	}
	var native windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &native); err != nil {
		return nil, nil, errors.Join(err, file.Close())
	}
	if native.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return nil, nil, errors.Join(ErrSymbolicLink, file.Close())
	}
	info, err := file.Stat()
	if err != nil {
		return nil, nil, errors.Join(err, file.Close())
	}
	if !info.Mode().IsRegular() {
		return nil, nil, errors.Join(ErrNotRegular, file.Close())
	}
	return file, info, nil
}
