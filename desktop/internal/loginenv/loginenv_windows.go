//go:build windows

package loginenv

// captureLoginEnvironment reports no login shell on Windows: the process environment is the
// user's own there, so there is nothing to read.
func captureLoginEnvironment() map[string]string { return nil }
