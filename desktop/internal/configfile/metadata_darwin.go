package configfile

/*
#include <copyfile.h>
#include <errno.h>
static int lithe_copy_config_metadata(int source, int target) {
    if (fcopyfile(source, target, NULL, COPYFILE_ACL | COPYFILE_XATTR) == 0) return 0;
    return errno;
}
*/
import "C"

import (
	"errors"
	"os"
	"syscall"
)

// Both descriptors are owned and held open through this synchronous native call.
func copyExtendedMetadata(source, target *os.File) error {
	sourceRaw, err := source.SyscallConn()
	if err != nil {
		return err
	}
	targetRaw, err := target.SyscallConn()
	if err != nil {
		return err
	}
	var copyErr, targetControlErr error
	err = sourceRaw.Control(func(sourceFD uintptr) {
		targetControlErr = targetRaw.Control(func(targetFD uintptr) {
			if code := C.lithe_copy_config_metadata(C.int(sourceFD), C.int(targetFD)); code != 0 {
				copyErr = syscall.Errno(code)
			}
		})
	})
	return errors.Join(err, targetControlErr, copyErr)
}
