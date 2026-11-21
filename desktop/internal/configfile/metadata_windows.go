package configfile

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

var reopenFile = windows.NewLazySystemDLL("kernel32.dll").NewProc("ReOpenFile")

func fileSecurity(file *os.File, fields windows.SECURITY_INFORMATION) (*windows.SECURITY_DESCRIPTOR, error) {
	raw, err := file.SyscallConn()
	if err != nil {
		return nil, err
	}
	var descriptor *windows.SECURITY_DESCRIPTOR
	var nativeErr error
	if err := raw.Control(func(fd uintptr) {
		descriptor, nativeErr = windows.GetSecurityInfo(windows.Handle(fd), windows.SE_FILE_OBJECT, fields)
	}); err != nil {
		return nil, err
	}
	return descriptor, nativeErr
}

func copyNativeMetadata(source, target *os.File) (err error) {
	const identities = windows.OWNER_SECURITY_INFORMATION | windows.GROUP_SECURITY_INFORMATION
	descriptor, err := fileSecurity(source, identities|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	targetDescriptor, err := fileSecurity(target, identities)
	if err != nil {
		return err
	}
	owner, _, err := descriptor.Owner()
	if err != nil {
		return err
	}
	group, _, err := descriptor.Group()
	if err != nil {
		return err
	}
	targetOwner, _, err := targetDescriptor.Owner()
	if err != nil {
		return err
	}
	targetGroup, _, err := targetDescriptor.Group()
	if err != nil {
		return err
	}

	fields := windows.SECURITY_INFORMATION(windows.DACL_SECURITY_INFORMATION)
	access := uint32(windows.READ_CONTROL | windows.WRITE_DAC)
	// Inherited Modify access permits file edits but does not grant WRITE_OWNER.
	// Only request it when the replacement would change an owner or group.
	if !owner.Equals(targetOwner) {
		fields |= windows.OWNER_SECURITY_INFORMATION
		access |= windows.WRITE_OWNER
	}
	if !group.Equals(targetGroup) {
		fields |= windows.GROUP_SECURITY_INFORMATION
		access |= windows.WRITE_OWNER
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
	var nativeErr error
	if err := targetRaw.Control(func(fd uintptr) {
		value, _, callErr := reopenFile.Call(fd,
			uintptr(access),
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
