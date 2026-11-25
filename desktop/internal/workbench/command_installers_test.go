package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

const commandInstallerPluginID = "dev.lithe.test.command-installers"

// commandInstallerManifest declares a language server and a debug adapter that run commands
// found on PATH, and an installer for each. Both installers run the fixture tool builder,
// which the tests resolve to the copied test binary running TestCommandInstallerTool.
const commandInstallerManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.command-installers",
  "displayName": "Command Installer Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"commandInstallers": 0, "debugAdapters": 0, "languageServers": 0, "languages": 0},
  "requiresTools": ["builder"],
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["commands.install", "debug.launch", "languageServer.launch"],
  "activationEvents": ["onDebug:fixture", "onLanguage:fixture"],
  "languages": [{"id": "fixture", "displayName": "Fixture", "fileExtensions": ["fixture"]}],
  "languageServers": [{
    "languageID": "fixture",
    "launch": {"kind": "systemCommand", "commands": ["lithe-fixture-ls"]},
    "arguments": ["serve"]
  }],
  "debugAdapters": [{
    "id": "fixture",
    "displayName": "Fixture DAP",
    "adapterID": "fixture-dap",
    "requests": ["launch"],
    "launch": {
      "process": {"launch": {"kind": "systemCommand", "commands": ["lithe-fixture-dap"]}, "arguments": ["--stdio"]},
      "transport": "stdio"
    }
  }],
  "commandInstallers": [
    {
      "id": "fixture-ls",
      "commands": ["lithe-fixture-ls"],
      "tool": "builder",
      "minimumVersion": "1.2",
      "arguments": ["-test.run=^TestCommandInstallerTool$", "install"],
      "mayUseNetwork": true,
      "timeoutSeconds": 60,
      "targets": {
        "managed": {"environment": {"FIXTURE_BIN": "${installDirectory}"}},
        "toolDefault": {"directory": [
          {"arguments": ["-test.run=^TestCommandInstallerTool$", "env", "FIXTURE_BIN"]},
          {"arguments": ["-test.run=^TestCommandInstallerTool$", "env", "FIXTURE_HOME"], "pathList": true, "append": "bin"}
        ]}
      }
    },
    {
      "id": "fixture-dap",
      "commands": ["lithe-fixture-dap"],
      "tool": "builder",
      "arguments": ["-test.run=^TestCommandInstallerTool$", "install"],
      "mayUseNetwork": false,
      "timeoutSeconds": 1,
      "targets": {
        "managed": {
          "arguments": ["-test.run=^TestCommandInstallerTool$", "install", "--prefix", "${installDirectory}"],
          "commandDirectory": "bin"
        }
      }
    }
  ]
}`

// The fixture tool's modes, read from LITHE_FIXTURE_COMMAND_TOOL.
const (
	// fixtureToolInstalls prints progress and writes the command where it installs.
	fixtureToolInstalls = "install"
	// fixtureToolFails prints an error and exits with code 3.
	fixtureToolFails = "fail"
	// fixtureToolInstallsNothing exits successfully without writing the command.
	fixtureToolInstallsNothing = "nothing"
	// fixtureToolHangs prints a line and then waits to be stopped.
	fixtureToolHangs = "hang"
)

// TestCommandInstallerTool is the fixture tool builder when the test binary runs as one. Like
// a real tool it installs into FIXTURE_BIN when told, and otherwise into the bin directory of
// the first FIXTURE_HOME entry; "env NAME" prints a variable as a directory probe reads it.
func TestCommandInstallerTool(t *testing.T) {
	mode := os.Getenv("LITHE_FIXTURE_COMMAND_TOOL")
	if mode == "" {
		t.Skip("not running as the fixture command tool")
	}
	arguments := flagArguments()
	if len(arguments) == 2 && arguments[0] == "env" {
		fmt.Println(os.Getenv(arguments[1]))
		os.Exit(0)
	}
	if len(arguments) == 0 || arguments[0] != "install" {
		os.Exit(2)
	}
	directory := os.Getenv("FIXTURE_BIN")
	command := "lithe-fixture-ls"
	if len(arguments) == 3 && arguments[1] == "--prefix" {
		directory, command = filepath.Join(arguments[2], "bin"), "lithe-fixture-dap"
	} else if directory == "" {
		directory = filepath.Join(filepath.SplitList(os.Getenv("FIXTURE_HOME"))[0], "bin")
	}
	switch mode {
	case fixtureToolFails:
		fmt.Fprintln(os.Stderr, "fixture: no such module")
		os.Exit(3)
	case fixtureToolInstallsNothing:
		os.Exit(0)
	case fixtureToolHangs:
		fmt.Println("fixture: downloading")
		// A stand-in for a download that never finishes: the host stops the process on its
		// timeout or a cancel. The bound only keeps an orphan from outliving the test run.
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	fmt.Println("fixture: downloading")
	fmt.Fprint(os.Stderr, "fixture: installed without a final newline")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		os.Exit(4)
	}
	if runtime.GOOS == "windows" {
		command += ".exe"
	}
	if err := os.WriteFile(filepath.Join(directory, command), []byte("fixture command"), 0o755); err != nil {
		os.Exit(5)
	}
	os.Exit(0)
}

// flagArguments are the arguments after the test binary's own flags.
func flagArguments() []string {
	for index, argument := range os.Args[1:] {
		if !strings.HasPrefix(argument, "-test.") {
			return os.Args[1+index:]
		}
	}
	return nil
}

// commandInstallerHarness installs the fixture plugin and resolves its tool to the copied test
// binary in mode, with FIXTURE_HOME naming two directories. It returns the harness, the tool's
// executable and FIXTURE_HOME's first directory.
func commandInstallerHarness(t *testing.T, mode string) (*harness, string, string) {
	t.Helper()
	h := debugPluginHarness(t, commandInstallerPluginID, commandInstallerManifest, false)
	name := "builder"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	executable := filepath.Join(t.TempDir(), name)
	copyTestBinary(t, executable)
	home := filepath.Join(t.TempDir(), "home")
	homes := home + string(filepath.ListSeparator) + filepath.Join(t.TempDir(), "other")
	h.app.toolchainResolve = func(_ context.Context, root, directory, tool, minimum string) (core.ToolchainSelection, error) {
		if !filepath.IsAbs(root) || directory != "." || tool != "builder" {
			t.Errorf("tool resolved in %q %q as %q", root, directory, tool)
		}
		if minimum != "" && minimum != "1.2" {
			t.Errorf("minimum version = %q", minimum)
		}
		return core.ToolchainSelection{
			Executable:  executable,
			Environment: map[string]string{"LITHE_FIXTURE_COMMAND_TOOL": mode, "FIXTURE_HOME": homes},
		}, nil
	}
	return h, executable, home
}

func commandInstallContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestCommandInstallsReportEveryLaunchMissingItsCommand(t *testing.T) {
	h, _, _ := commandInstallerHarness(t, fixtureToolInstalls)
	installs := settingsCommandInstalls{app: h.app}
	missing, err := installs.Missing(commandInstallContext(t), commandInstallerPluginID)
	if err != nil {
		t.Fatal(err)
	}
	expected := []settingswindow.MissingCommand{
		{Kind: settingswindow.CapabilityLanguageServer, ID: "fixture", Commands: []string{"lithe-fixture-ls"}, Installer: "fixture-ls", Tool: "builder"},
		{Kind: settingswindow.CapabilityDebugger, ID: "fixture", Commands: []string{"lithe-fixture-dap"}, Installer: "fixture-dap", Tool: "builder"},
	}
	slices.SortFunc(missing, func(a, b settingswindow.MissingCommand) int { return strings.Compare(b.Kind, a.Kind) })
	slices.SortFunc(expected, func(a, b settingswindow.MissingCommand) int { return strings.Compare(b.Kind, a.Kind) })
	if !reflect.DeepEqual(missing, expected) {
		t.Fatalf("missing = %+v\nwant %+v", missing, expected)
	}
}

func TestCommandInstallOfferShowsEachTargetExpanded(t *testing.T) {
	h, executable, home := commandInstallerHarness(t, fixtureToolInstalls)
	installs := settingsCommandInstalls{app: h.app}
	ctx := commandInstallContext(t)
	managed, err := h.app.plugins.Commands.InstallDirectory(commandInstallerPluginID, "fixture-ls")
	if err != nil {
		t.Fatal(err)
	}
	offer, err := installs.Offer(ctx, commandInstallerPluginID, "fixture-ls")
	if err != nil {
		t.Fatal(err)
	}
	command := quoteArguments([]string{executable, "-test.run=^TestCommandInstallerTool$", "install"})
	expected := settingswindow.CommandInstallOffer{
		Installer:     "fixture-ls",
		Commands:      []string{"lithe-fixture-ls"},
		Tool:          "builder",
		Executable:    executable,
		MayUseNetwork: true,
		Timeout:       time.Minute,
		Targets: []settingswindow.CommandInstallTarget{
			{Target: core.CommandInstallManaged, CommandLine: command, Environment: []string{"FIXTURE_BIN=" + managed}, Directory: managed},
			// FIXTURE_BIN is unset, so the second probe names the default directory.
			{Target: core.CommandInstallToolDefault, CommandLine: command, Environment: []string{}, Directory: filepath.Join(home, "bin")},
		},
	}
	if !reflect.DeepEqual(offer, expected) {
		t.Fatalf("offer = %+v\nwant %+v", offer, expected)
	}

	offer, err = installs.Offer(ctx, commandInstallerPluginID, "fixture-dap")
	if err != nil {
		t.Fatal(err)
	}
	prefix, err := h.app.plugins.Commands.InstallDirectory(commandInstallerPluginID, "fixture-dap")
	if err != nil {
		t.Fatal(err)
	}
	if len(offer.Targets) != 1 || offer.MayUseNetwork || offer.Timeout != time.Second ||
		offer.Targets[0].Directory != filepath.Join(prefix, "bin") ||
		offer.Targets[0].CommandLine != quoteArguments([]string{executable, "-test.run=^TestCommandInstallerTool$", "install", "--prefix", prefix}) {
		t.Fatalf("offer with a command directory = %+v", offer)
	}
	if _, err := os.Stat(prefix); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("an offer created the install directory: %v", err)
	}
}

// commandOutput collects an installation's output lines.
type commandOutput struct {
	mu    sync.Mutex
	lines []string
}

func (o *commandOutput) add(line string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.lines = append(o.lines, line)
}

func (o *commandOutput) all() []string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]string(nil), o.lines...)
}

func TestCommandInstallManagedRecordsWhereLaterLaunchesFindTheCommand(t *testing.T) {
	h, _, _ := commandInstallerHarness(t, fixtureToolInstalls)
	installs := settingsCommandInstalls{app: h.app}
	ctx := commandInstallContext(t)
	managed, err := h.app.plugins.Commands.InstallDirectory(commandInstallerPluginID, "fixture-ls")
	if err != nil {
		t.Fatal(err)
	}
	// The tool's working directory is made under os.TempDir(), which other test runs on the
	// machine share; a private one keeps their installs out of the check below.
	private, err := os.MkdirTemp("", "lci-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(private); err != nil {
			t.Error(err)
		}
	})
	for _, name := range []string{"TMPDIR", "TMP", "TEMP"} {
		t.Setenv(name, private)
	}
	var output commandOutput
	directory, err := installs.Install(ctx, commandInstallerPluginID, "fixture-ls", core.CommandInstallManaged, output.add, nil)
	if err != nil {
		t.Fatal(err)
	}
	if directory != managed {
		t.Fatalf("installed into %q, want %q", directory, managed)
	}
	lines := output.all()
	if !slices.Contains(lines, "fixture: downloading") || !slices.Contains(lines, "fixture: installed without a final newline") {
		t.Fatalf("output = %q", lines)
	}
	installations := h.app.plugins.Commands.Installations(commandInstallerPluginID)
	if !reflect.DeepEqual(installations, []pluginhost.CommandInstallation{{Installer: "fixture-ls", Target: core.CommandInstallManaged, Directory: managed}}) {
		t.Fatalf("recorded %+v", installations)
	}
	path, err := h.app.plugins.Backend.ResolveCommand(commandInstallerPluginID, []string{"lithe-fixture-ls"})
	if err != nil || filepath.Dir(path) != managed {
		t.Fatalf("language server command = %q, %v", path, err)
	}
	missing, err := installs.Missing(ctx, commandInstallerPluginID)
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 1 || missing[0].Kind != settingswindow.CapabilityDebugger {
		t.Fatalf("still missing after the install: %+v", missing)
	}
	entries, err := os.ReadDir(private)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "lithe-command-install-") {
			t.Errorf("the tool's working directory %s was left behind", entry.Name())
		}
	}
}

func TestCommandInstallToolDefaultRecordsTheProbedDirectory(t *testing.T) {
	h, _, home := commandInstallerHarness(t, fixtureToolInstalls)
	installs := settingsCommandInstalls{app: h.app}
	directory, err := installs.Install(commandInstallContext(t), commandInstallerPluginID, "fixture-ls", core.CommandInstallToolDefault, func(string) {}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if directory != filepath.Join(home, "bin") {
		t.Fatalf("installed into %q, want the probed default directory", directory)
	}
	installations := h.app.plugins.Commands.Installations(commandInstallerPluginID)
	if !reflect.DeepEqual(installations, []pluginhost.CommandInstallation{{Installer: "fixture-ls", Target: core.CommandInstallToolDefault, Directory: directory}}) {
		t.Fatalf("recorded %+v", installations)
	}
}

func TestCommandInstallReportsWhyTheCommandsDidNotLand(t *testing.T) {
	for _, test := range []struct {
		name, mode, installer string
		check                 func(t *testing.T, failure *pluginhost.CommandInstallError, directory string)
	}{
		{"nonzero exit", fixtureToolFails, "fixture-ls", func(t *testing.T, failure *pluginhost.CommandInstallError, _ string) {
			if failure.Code != pluginhost.CommandInstallFailedCode || failure.ExitCode != 3 {
				t.Fatalf("failure = %+v", failure)
			}
		}},
		{"command not written", fixtureToolInstallsNothing, "fixture-ls", func(t *testing.T, failure *pluginhost.CommandInstallError, directory string) {
			if failure.Code != pluginhost.CommandInstallCommandsMissingCode || failure.Directory != directory ||
				!reflect.DeepEqual(failure.Commands, []string{"lithe-fixture-ls"}) {
				t.Fatalf("failure = %+v, want lithe-fixture-ls missing from %s", failure, directory)
			}
		}},
		{"past the timeout", fixtureToolHangs, "fixture-dap", func(t *testing.T, failure *pluginhost.CommandInstallError, _ string) {
			if failure.Code != pluginhost.CommandInstallTimedOutCode || failure.Timeout != time.Second {
				t.Fatalf("failure = %+v", failure)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			h, _, _ := commandInstallerHarness(t, test.mode)
			logger := &treeRecordingLog{}
			h.app.logSink = logger
			installs := settingsCommandInstalls{app: h.app}
			directory, err := h.app.plugins.Commands.InstallDirectory(commandInstallerPluginID, test.installer)
			if err != nil {
				t.Fatal(err)
			}
			installed, err := installs.Install(commandInstallContext(t), commandInstallerPluginID, test.installer, core.CommandInstallManaged, func(string) {}, nil)
			var failure *pluginhost.CommandInstallError
			if !errors.As(err, &failure) {
				t.Fatalf("Install = %q, %v; want a CommandInstallError", installed, err)
			}
			test.check(t, failure, directory)
			if installations := h.app.plugins.Commands.Installations(commandInstallerPluginID); len(installations) != 0 {
				t.Fatalf("a failed installation was recorded: %+v", installations)
			}
			// The click and the failure the dialog shows are each logged once.
			if n := countPerformed(logger, "plugin.commandInstaller.install"); n != 1 {
				t.Fatalf("the install action was logged %d times", n)
			}
			if failed := loggedEvents(logger, operationFailedEvent); len(failed) != 1 || failed[0].Fields["operation"] != "plugin_command_install" {
				t.Fatalf("operation failures = %+v, want the one install failure", failed)
			}
		})
	}
}

func TestCommandInstallStopsTheToolWhenCancelled(t *testing.T) {
	h, _, _ := commandInstallerHarness(t, fixtureToolHangs)
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	installs := settingsCommandInstalls{app: h.app}
	ctx, cancel := context.WithCancel(commandInstallContext(t))
	defer cancel()
	// The tool prints its first line once it runs; cancelling then stops it mid-installation.
	_, err := installs.Install(ctx, commandInstallerPluginID, "fixture-ls", core.CommandInstallManaged, func(line string) {
		if line == "fixture: downloading" {
			cancel()
		}
	}, nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Install = %v, want the cancel", err)
	}
	if installations := h.app.plugins.Commands.Installations(commandInstallerPluginID); len(installations) != 0 {
		t.Fatalf("a cancelled installation was recorded: %+v", installations)
	}
	// A cancel is not a failure.
	if failed := loggedEvents(logger, operationFailedEvent); len(failed) != 0 {
		t.Fatalf("the cancel was logged as a failure: %+v", failed)
	}
}

func TestCommandInstallRefusesATargetTheInstallerLacks(t *testing.T) {
	h, _, _ := commandInstallerHarness(t, fixtureToolInstalls)
	installs := settingsCommandInstalls{app: h.app}
	if _, err := installs.Install(commandInstallContext(t), commandInstallerPluginID, "fixture-dap", core.CommandInstallToolDefault, func(string) {}, nil); err == nil {
		t.Fatal("installed into a target the installer does not declare")
	}
	if _, err := installs.Offer(commandInstallContext(t), commandInstallerPluginID, "absent"); err == nil {
		t.Fatal("offered an installer the plugin does not declare")
	}
}

func TestCommandOutputLinesSplitEachStream(t *testing.T) {
	var output commandOutput
	lines := &commandOutputLines{send: output.add}
	lines.write(buildprocess.Stdout, "one\ntw")
	lines.write(buildprocess.Stderr, "warn")
	lines.write(buildprocess.Stdout, "o\r\nthree")
	lines.write(buildprocess.Stderr, "ing\n"+strings.Repeat("x", maxCommandOutputLine+10)+"\n")
	lines.flush()
	got := output.all()
	expected := []string{"one", "two", "warning", strings.Repeat("x", maxCommandOutputLine), "three"}
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("lines = %q\nwant %q", got, expected)
	}
}

func TestCommandMissingFailuresAreLocalized(t *testing.T) {
	err := fmt.Errorf("start: %w", &pluginhost.CommandMissingError{Commands: []string{"lithe-fixture-ls", "lithe-fixture-ls2"}})
	message, ok := commandMissingMessage(i18n.English, err)
	if !ok || !strings.Contains(message, "lithe-fixture-ls | lithe-fixture-ls2") || strings.Contains(message, "plugin.command.missing") {
		t.Fatalf("message = %q, %v", message, ok)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	launch := h.app.launchFailureText(err)
	if launch != i18n.SharedFormat(h.app.language(), "desktop.plugins.commandMissingHelp", map[string]string{"commands": "lithe-fixture-ls | lithe-fixture-ls2"}) {
		t.Fatalf("launch failure = %q", launch)
	}
	if text := h.app.vcsFailureText(err); text != launch {
		t.Fatalf("version control failure = %q, want %q", text, launch)
	}
	if _, ok := commandMissingMessage(i18n.English, errors.New("other")); ok {
		t.Fatal("an unrelated failure counted as a missing command")
	}
}

func TestCommandInstallerFallsBackToToolIDAndRecordsUnreadableCatalog(t *testing.T) {
	const plugin = "dev.lithe.test.incomplete"
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, plugin, "1.0.0"), 0o700); err != nil {
		t.Fatal(err)
	}
	prefs := store.At(t.TempDir())
	if err := pluginstate.New(prefs).SetEnabled(plugin, true); err != nil {
		t.Fatal(err)
	}
	service, err := pluginservice.Open(core.NewClient(), prefs, root)
	if err != nil {
		t.Fatal(err)
	}
	log := &treeRecordingLog{}
	installer := settingsCommandInstalls{app: &App{plugins: service, logSink: log}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const tool = plugin + ":compiler"
	if name := toolName(installer.toolNames(ctx), tool); name != tool {
		t.Fatalf("fallback = %q, want %q", name, tool)
	}
	if len(log.events) != 1 || log.events[0].Fields["operation"] != "command_installer_tool_discovery" {
		t.Fatalf("expected one discovery diagnostic, got %+v", log.events)
	}
}
