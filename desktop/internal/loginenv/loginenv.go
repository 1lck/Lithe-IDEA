// Package loginenv gives the environment a login shell sets up for the user.
//
// An app started from Finder or the Dock inherits launchd's minimal environment, which
// lacks the PATH the user's shell profile builds. Toolchains and runs started from such
// an app would then miss the tools the user has installed. The login shell's environment
// is read once per process, bounded in time, and only the PATH is taken from it when the
// process has none of its own.
package loginenv

import (
	"os"
	"sync"
)

var (
	once     sync.Once
	captured map[string]string
)

// Environment is the login shell's environment, read once. It is nil when the platform
// has no login shell to ask or the shell does not answer in time; callers then keep the
// inherited environment.
func Environment() map[string]string {
	once.Do(func() { captured = captureLoginEnvironment() })
	return captured
}

// Path is the PATH a launch should start with: the login shell's when it has one, else the
// process's own. An empty result means neither is set.
func Path() string {
	if value, ok := Environment()["PATH"]; ok && value != "" {
		return value
	}
	return os.Getenv("PATH")
}
