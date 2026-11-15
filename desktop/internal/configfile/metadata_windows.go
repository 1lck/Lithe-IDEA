package configfile

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

var reopenFile = windows.NewLazySystemDLL("kernel32.dll").NewProc("ReOpenFile")

func copyNativeMetadata(source, target *os.File) (err error) {
	fields := windows.SECURITY_INFORMATION(windows.OWNER_SECURITY_INFORMATION | windows.GROUP_SECURITY_INFORMATION | windows.DACL_SECURITY_INFORMATION)
	sourceRaw, err := source.SyscallConn()
	if err != nil {
		return err
	}
	var descriptor *windows.SECURITY_DESCRIPTOR
	var nativeErr error
	if err := sourceRaw.Control(func(fd uintptr) {
		descriptor, nativeErr = windows.GetSecurityInfo(windows.Handle(fd), windows.SE_FILE_OBJECT, fields)
	}); err != nil {
		return err
	}
	if nativeErr != nil {
		return nativeErr
	}
	owner, _, err := descriptor.Owner()
	if err != nil {
		return err
	}
	group, _, err := descriptor.Group()
	if err != nil {
		return err
	}
	dacl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	control, _, err := descriptor.Control()
	if err != nil {
		return err
	}
	if control&windows.SE_DACL_PROTECTED != 0 {
		fields |= windows.PROTECTED_DACL_SECURITY_INFORMATION
	} else {
		fields |= windows.UNPROTECTED_DACL_SECURITY_INFORMATION
	}
	targetRaw, err := target.SyscallConn()
	if err != nil {
		return err
	}
	var handle windows.Handle
	if err := targetRaw.Control(func(fd uintptr) {
		value, _, callErr := reopenFile.Call(fd,
			uintptr(windows.READ_CONTROL|windows.WRITE_DAC|windows.WRITE_OWNER),
			uintptr(windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE), 0)
		handle = windows.Handle(value)
		if handle == windows.InvalidHandle {
			nativeErr = callErr
		}
	}); err != nil {
		return err
	}
	if nativeErr != nil {
		return nativeErr
	}
	defer func() { err = errors.Join(err, windows.CloseHandle(handle)) }()
	return windows.SetSecurityInfo(handle, windows.SE_FILE_OBJECT, fields, owner, group, dacl, nil)
}
