// Command lithe is the Lithe desktop client: one window with the start screen and the
// workbench of an open project, painted with Viva on top of the Rust kernel.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/workbench"
)

func main() {
	// Git and SSH run this program as the AskPass helper of a Git command the user started in
	// Lithe. The helper only relays one question to that window and prints the answer, so it
	// returns before any window, log, store or login environment exists.
	if prompt, helper := core.GitAskPassRequest(os.Args); helper {
		os.Exit(core.GitAskPass(prompt))
	}
	// AppKit needs the process's main thread for the application and its windows. Pin the
	// main goroutine before any setup that can yield, so the scheduler cannot move it.
	runtime.LockOSThread()
	client := core.NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	launch, err := client.PlanCLILaunch(ctx, os.Args[1:])
	cancel()
	if err != nil {
		fail(err)
	}
	switch launch.Action {
	case "help":
		fmt.Println(i18n.Shared(i18n.Detect([]string{os.Getenv("LC_ALL"), os.Getenv("LC_MESSAGES"), os.Getenv("LANG")}), "desktop.cli.usage"))
		return
	case "version":
		fmt.Println(desktop.Version())
		return
	}
	path, file, err := commandLineTarget(client, launch.Path)
	if err != nil {
		fail(err)
	}
	if launch.Detach {
		if err := launchGUI(path); err != nil {
			fail(err)
		}
		return
	}
	// An app started from Finder or the Dock gets only the system PATH; take the login shell's
	// before any project services start. The CLI requests above are synchronous pure rules.
	var refreshLoginEnvironment func()
	if !file {
		refreshLoginEnvironment = loginenv.Activate()
	}
	preferences, err := store.Open()
	if err != nil {
		fail(err)
	}
	if refreshLoginEnvironment != nil {
		go refreshLoginEnvironment()
	}
	version := desktop.Version()
	options := workbench.DesktopOptions(client, preferences, version)
	if file {
		options.OpenFile = path
	} else {
		options.OpenPath = path
	}
	// A log that cannot be opened leaves the client without its log window instead of
	// keeping it from starting; the window says so when the log is asked for.
	logs, err := logstore.Open(logstore.Options{Kernel: client, Settings: preferences, Version: version})
	if err != nil {
		fmt.Fprintln(os.Stderr, "lithe: log:", err)
	} else {
		// Core holds one waker for the process; this client's log is the one that drains it.
		logs.ObserveCoreFacts()
		// The runtime writes a fatal crash only to stderr, which a packaged app sends nowhere;
		// the log keeps it for the next start, and tells how earlier sessions ended.
		logs.CaptureCrashes()
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

// commandLineTarget observes the native file type; Core selects the session policy.
func commandLineTarget(client *core.Client, path string) (string, bool, error) {
	if path == "" {
		return "", false, nil
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", false, err
	}
	abs, err = filepath.EvalSymlinks(abs)
	if err != nil {
		return "", false, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", false, err
	}
	kind := "other"
	if info.IsDir() {
		kind = "directory"
	} else if info.Mode().IsRegular() {
		kind = "file"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	target, err := client.CLIOpenTarget(ctx, kind)
	return abs, target.Mode == "file", err
}

// The shell launcher exits after starting the GUI, without a shell subprocess or
// inherited terminal streams. The child receives an absolute path and no --cli.
func launchGUI(path string) error {
	executable, err := installedpackage.Executable()
	if err != nil {
		return err
	}
	args := []string{}
	if path != "" {
		args = []string{"--", path}
	}
	cmd := exec.Command(executable, args...)
	detachGUI(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

// fail reports an error that keeps the client from starting or running and exits.
func fail(err error) {
	fmt.Fprintln(os.Stderr, "lithe:", err)
	os.Exit(1)
}
