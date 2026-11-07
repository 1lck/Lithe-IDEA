// Command lithe is the Lithe desktop client: one window with the start screen and the
// workbench of an open project, painted with Viva on top of the Rust kernel.
package main

import (
	"fmt"
	"os"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/workbench"
)

// version is the client's version, written into every log file header. Release builds set
// it with -ldflags "-X main.version=<version>".
var version = "0.0.0"

func main() {
	// AppKit needs the process's main thread for the application and its windows. Pin the
	// main goroutine before any setup that can yield, so the scheduler cannot move it.
	runtime.LockOSThread()
	preferences, err := store.Open()
	if err != nil {
		fail(err)
	}
	client := core.NewClient()
	options := workbench.Options{Kernel: client, Store: preferences, LogKernel: client, Version: version}
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

// fail reports an error that keeps the client from starting or running and exits.
func fail(err error) {
	fmt.Fprintln(os.Stderr, "lithe:", err)
	os.Exit(1)
}
