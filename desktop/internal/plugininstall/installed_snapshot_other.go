//go:build !unix

package plugininstall

import "os"

const snapshotReadFlags = os.O_RDONLY
