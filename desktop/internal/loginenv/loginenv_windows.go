//go:build windows

package loginenv

import "time"

// refreshTimeout is unused on Windows; it keeps the shared code platform-neutral.
const refreshTimeout = time.Second

// Activate does nothing on Windows: a GUI program inherits the user's whole environment from the
// registry there.
func Activate() func() {
	mu.Lock()
	activated = true
	mu.Unlock()
	return nil
}

// captureLoginEnvironment reports no login shell on Windows: the process environment is the
// user's own there, so there is nothing to read.
func captureLoginEnvironment(time.Duration) map[string]string { return nil }
