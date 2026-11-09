package toolchain

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// Note: .agents/notes/implemented/bug-fix/2026-11-09-viva-windows-native-file-validation.md
// Preserve native file permissions on the unpublished temporary file before
// renaming it. A metadata failure therefore leaves the captured source intact.
func publishProtectedFile(temporary, target string, check func() error) error {
	fields := windows.SECURITY_INFORMATION(windows.OWNER_SECURITY_INFORMATION | windows.GROUP_SECURITY_INFORMATION | windows.DACL_SECURITY_INFORMATION)
	descriptor, err := windows.GetNamedSecurityInfo(target, windows.SE_FILE_OBJECT, fields)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND) {
		if err := check(); err != nil {
			return err
		}
		return os.Rename(temporary, target)
	}
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
	if err := windows.SetNamedSecurityInfo(temporary, windows.SE_FILE_OBJECT, fields, owner, group, dacl, nil); err != nil {
		return err
	}
	if err := check(); err != nil {
		return err
	}
	return os.Rename(temporary, target)
}
