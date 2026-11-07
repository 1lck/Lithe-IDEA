//go:build !windows

package term

// win32InputSupported is false because the protocol describes Windows console
// key records, which other platforms do not have.
const win32InputSupported = false
