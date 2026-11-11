// Package loginenv gives the environment a login shell sets up for the user (matrix id
// login-shell-environment).
//
// An app started from Finder or the Dock inherits launchd's minimal environment
// (PATH=/usr/bin:/bin:/usr/sbin:/sbin), which lacks what the user's shell profile builds, so
// tools installed through Homebrew, mise, SDKMAN, asdf or fnm are invisible to toolchain
// discovery and to every process the client starts. Activate, at startup and before Core starts
// threads that read the environment, puts the login shell's PATH in front of the process's own,
// so Core's language servers, Git and agents get it too. Starting an interactive login shell takes
// about a second with typical rc files, so only PATH is cached, in the user's cache directory and
// never the application: a warm start applies the cached PATH at once and reads the shell again
// in the background for the next launch. The shell's other variables may hold secrets, so they
// stay in memory and only fill what a child the client starts lacks (Environ).
// LITHE_SKIP_SHELL_ENV turns the read off.
//
// The approach follows OpenIDEA's crates/ide-host/src/shell_env.rs (Apache-2.0), as the macOS
// client did.
package loginenv

import (
	"os"
	"strings"
	"sync"
)

// SkipVariable turns the read off, for tests and for rc files that must not run unattended; the
// read sets it for the shell, so a profile that starts Lithe does not loop back into it.
const SkipVariable = "LITHE_SKIP_SHELL_ENV"

var (
	mu        sync.Mutex
	captured  map[string]string
	activated bool
	once      sync.Once
)

// shellOwnVariables are the ones a shell sets for itself or its terminal rather than from the
// user's profile; a process the client starts is not in that terminal.
var shellOwnVariables = map[string]bool{
	"PWD": true, "OLDPWD": true, "SHLVL": true, "_": true, "TERM": true,
	"TERM_PROGRAM": true, "TERM_PROGRAM_VERSION": true, "TERM_SESSION_ID": true,
}

// Environment is the login shell's environment. After Activate it is what the last read found,
// nil until a warm start's background read finishes; without Activate (tests, tools) the shell
// is read once on first use. It is nil when there is no login shell to ask or it did not answer
// in time; callers then keep the inherited environment.
func Environment() map[string]string {
	mu.Lock()
	if activated {
		defer mu.Unlock()
		return captured
	}
	mu.Unlock()
	once.Do(func() {
		if os.Getenv(SkipVariable) != "" {
			return
		}
		values := captureLoginEnvironment(refreshTimeout)
		mu.Lock()
		captured = values
		mu.Unlock()
	})
	mu.Lock()
	defer mu.Unlock()
	return captured
}

// Path is the PATH a launch should start with. After Activate that is the process's own, which
// already begins with the login shell's; otherwise the login shell's when it has one, else the
// process's. An empty result means neither is set.
func Path() string {
	mu.Lock()
	done := activated
	mu.Unlock()
	if !done {
		if value := Environment()["PATH"]; value != "" {
			return value
		}
	}
	return os.Getenv("PATH")
}

// Environ is the process's environment plus the login shell's variables it lacks: what a child
// process the client starts should get. A value the process already has always wins.
func Environ() []string {
	return Merged(os.Environ())
}

// Merged is base ("KEY=value" entries) plus the login shell's variables, PATH aside, that base
// does not define.
func Merged(base []string) []string {
	mu.Lock()
	extra := captured
	mu.Unlock()
	if len(extra) == 0 {
		return base
	}
	have := make(map[string]bool, len(base))
	for _, entry := range base {
		if key, _, ok := strings.Cut(entry, "="); ok {
			have[key] = true
		}
	}
	out := append([]string(nil), base...)
	for key, value := range extra {
		if key != "PATH" && !have[key] {
			out = append(out, key+"="+value)
		}
	}
	return out
}

// remember keeps a read's variables for Environment and Environ.
func remember(values map[string]string) {
	mu.Lock()
	captured = values
	mu.Unlock()
}

// mergedPath is the login shell's entries first, as in a terminal, then the inherited ones it
// lacks, so a client started from a terminal keeps that session's additions.
func mergedPath(login, inherited string) string {
	seen := map[string]bool{}
	var entries []string
	for _, entry := range append(strings.Split(login, ":"), strings.Split(inherited, ":")...) {
		if entry != "" && !seen[entry] {
			seen[entry] = true
			entries = append(entries, entry)
		}
	}
	return strings.Join(entries, ":")
}

// marker frames the environment in the shell's output, so a greeting the profile prints is
// skipped and a cut-off read is recognized.
const marker = "__LITHE_LOGIN_ENV__"

// parse reads `env -0` output between the two markers; nil when either is missing.
func parse(data []byte) map[string]string {
	text := string(data)
	start := strings.Index(text, marker)
	if start < 0 {
		return nil
	}
	rest := text[start+len(marker):]
	end := strings.Index(rest, marker)
	if end < 0 {
		return nil
	}
	result := map[string]string{}
	for _, entry := range strings.Split(rest[:end], "\x00") {
		key, value, ok := strings.Cut(entry, "=")
		if ok && key != "" && !shellOwnVariables[key] {
			result[key] = value
		}
	}
	return result
}
