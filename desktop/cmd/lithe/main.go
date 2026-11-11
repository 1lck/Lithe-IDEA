// Command lithe is the Lithe desktop client: one window with the start screen and the
// workbench of an open project, painted with Viva on top of the Rust kernel.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/workbench"
)

func main() {
	// AppKit needs the process's main thread for the application and its windows. Pin the
	// main goroutine before any setup that can yield, so the scheduler cannot move it.
	runtime.LockOSThread()
	preferences, err := store.Open()
	if err != nil {
		fail(err)
	}
	client := core.NewClient()
	version := desktop.Version()
	options := workbench.DesktopOptions(client, preferences, version)
	// A project folder given on the command line is opened when the window starts; a worktree's
	// "Open in New Window" starts the client that way.
	if folder := commandLineFolder(os.Args[1:]); folder != "" {
		options.OpenPath = folder
	}
	// A log that cannot be opened leaves the client without its log window instead of
	// keeping it from starting; the window says so when the log is asked for.
	logs, err := logstore.Open(logstore.Options{Kernel: client, Settings: preferences, Version: version})
	if err != nil {
		fmt.Fprintln(os.Stderr, "lithe: log:", err)
	} else {
		options.Logs = logs
	}
	err = workbench.New(options).Run()
	// os.Exit skips deferred calls, so the log is closed, and its queue written, here.
	if logs != nil {
		logs.Close()
	}
	if err != nil {
		fail(err)
	}
}

// commandLineFolder is the first argument that names an existing folder, made absolute; empty when
// there is none.
func commandLineFolder(args []string) string {
	for _, arg := range args {
		abs, err := filepath.Abs(arg)
		if err != nil {
			continue
		}
		if info, err := os.Stat(abs); err == nil && info.IsDir() {
			return abs
		}
	}
	return ""
}

// fail reports an error that keeps the client from starting or running and exits.
func fail(err error) {
	fmt.Fprintln(os.Stderr, "lithe:", err)
	os.Exit(1)
}
