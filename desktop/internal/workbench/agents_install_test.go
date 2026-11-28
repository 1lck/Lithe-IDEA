package workbench

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

const agentInstallerPluginID = "dev.lithe.test.agent-installer"

// agentInstallerCommand is the agent CLI's command, a name nothing on a test machine's PATH has.
const agentInstallerCommand = "lithe-test-agent-cli"

// agentInstallerManifest declares an agent whose tool is the plugin's own definition of the CLI,
// and an installer that installs the CLI with the plugin's package tool into a managed prefix.
// The CLI's layout is bin/<command> below the prefix, where the test puts the copied test binary,
// which answers --version as SyntheticInterp when syntheticWorkbenchInterpMarkerEnv is set.
func agentInstallerManifest() string {
	layout := "bin/" + agentInstallerCommand
	if runtime.GOOS == "windows" {
		layout += ".exe"
	}
	return fmt.Sprintf(`{
  "schemaVersion": 0,
  "id": %[1]q,
  "displayName": "Agent Installer Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"agents": 0, "commandInstallers": 0, "toolDefinitions": 0},
  "requiresTools": [%[3]q, %[2]q],
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["agents.run", "commands.install"],
  "activationEvents": [],
  "agents": [{"id": "example", "displayName": "Example Agent", "tool": %[3]q, "terminal": {"arguments": []}}],
  "toolDefinitions": [
    {
      "id": %[3]q,
      "displayName": "Example Agent CLI",
      "executableLayouts": [{"path": %[4]q}],
      "executables": [{"id": "shell", "kind": "command", "command": %[5]q}],
      "version": {"arguments": ["--version"], "pattern": "SyntheticInterp (\\d+(?:\\.\\d+)*)"},
      "commands": [%[5]q],
      "launch": ["${executable}", "${arguments}"]
    },
    {
      "id": %[2]q,
      "displayName": "Package Tool",
      "executableLayouts": [{"path": "bin/lithe-test-packages"}],
      "executables": [{"id": "shell", "kind": "command", "command": "lithe-test-packages"}],
      "version": {"arguments": ["--version"], "pattern": "(\\d+(?:\\.\\d+)*)"},
      "commands": ["lithe-test-packages"],
      "launch": ["${executable}", "${arguments}"]
    }
  ],
  "commandInstallers": [{
    "id": "agent-cli",
    "commands": [%[5]q],
    "tool": %[2]q,
    "arguments": ["install", "--global", "example-agent"],
    "mayUseNetwork": true,
    "targets": {
      "managed": {"arguments": ["install", "--prefix", "${installDirectory}", "example-agent"], "commandDirectory": "bin"}
    }
  }]
}`, agentInstallerPluginID, agentInstallerPluginID+":packages", agentInstallerPluginID+":cli", layout, agentInstallerCommand)
}

func TestAgentCLIInstalledForThePluginIsFoundOffPath(t *testing.T) {
	t.Setenv(syntheticWorkbenchInterpMarkerEnv, filepath.Join(t.TempDir(), "probed"))
	h := debugPluginHarness(t, agentInstallerPluginID, agentInstallerManifest(), false)
	installs := settingsCommandInstalls{app: h.app}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	missing, err := installs.Missing(ctx, agentInstallerPluginID)
	if err != nil {
		t.Fatal(err)
	}
	want := []settingswindow.MissingCommand{{Kind: settingswindow.CapabilityAgent, ID: "example", Commands: []string{agentInstallerCommand}, Installer: "agent-cli", Tool: "Package Tool"}}
	if !reflect.DeepEqual(missing, want) {
		t.Fatalf("missing before the install = %+v\nwant %+v", missing, want)
	}
	_, err = h.app.resolveAgentTool(ctx, "", agentInstallerPluginID, agentInstallerPluginID+":cli")
	if !agentToolMissing(err) {
		t.Fatalf("an uninstalled CLI resolved with %v, want a missing CLI", err)
	}

	// What a managed install leaves: the CLI below the prefix, and the record of its directory.
	prefix, err := h.app.plugins.Commands.InstallDirectory(agentInstallerPluginID, "agent-cli")
	if err != nil {
		t.Fatal(err)
	}
	name := agentInstallerCommand
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	executable := filepath.Join(prefix, "bin", name)
	if err := os.MkdirAll(filepath.Dir(executable), 0o755); err != nil {
		t.Fatal(err)
	}
	copyTestBinary(t, executable)
	if err := h.app.plugins.Commands.Record(agentInstallerPluginID, pluginhost.CommandInstallation{
		Installer: "agent-cli", Target: core.CommandInstallManaged, Directory: filepath.Dir(executable),
	}); err != nil {
		t.Fatal(err)
	}

	tool, err := h.app.resolveAgentTool(ctx, "", agentInstallerPluginID, agentInstallerPluginID+":cli")
	if err != nil {
		t.Fatalf("the installed CLI did not resolve: %v", err)
	}
	canonical, err := toolchain.CanonicalPath(executable)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Clean(tool.Path) != filepath.Clean(canonical) {
		t.Fatalf("resolved %q, want the installed %q", tool.Path, canonical)
	}
	missing, err = installs.Missing(ctx, agentInstallerPluginID)
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 0 {
		t.Fatalf("still missing after the install: %+v", missing)
	}
}

func TestAgentCommandLookupTriesPathFirstAndCanonicalizesInstalledHits(t *testing.T) {
	store := &pluginhost.CommandStore{State: t.TempDir()}
	directory := filepath.Join(t.TempDir(), "bin")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	name := agentInstallerCommand
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	copyTestBinary(t, filepath.Join(directory, name))
	if err := store.Record(agentInstallerPluginID, pluginhost.CommandInstallation{
		Installer: "agent-cli", Target: core.CommandInstallManaged, Directory: directory,
	}); err != nil {
		t.Fatal(err)
	}
	want, err := toolchain.CanonicalPath(filepath.Join(directory, name))
	if err != nil {
		t.Fatal(err)
	}
	if path, err := agentCommandLookup(store, agentInstallerPluginID)(agentInstallerCommand); err != nil || path != want {
		t.Fatalf("installed command = %q, %v; want %q", path, err, want)
	}
	if _, err := agentCommandLookup(store, "dev.lithe.test.other")(agentInstallerCommand); err == nil {
		t.Fatal("another plugin's installed command was found")
	}
	if _, err := agentCommandLookup(nil, agentInstallerPluginID)(agentInstallerCommand); err == nil {
		t.Fatal("a lookup without a command store found an installed command")
	}
}

func TestAgentToolMissingIsOnlyAMissingInstallation(t *testing.T) {
	cases := []struct {
		err  error
		want bool
	}{
		{&toolchain.UnavailableError{Tool: "cli", Code: "toolchain.unavailable"}, true},
		{fmt.Errorf("start: %w", &toolchain.UnavailableError{Tool: "cli"}), true},
		{&toolchain.UnavailableError{Terminal: true, Tool: "cli"}, false},
		{&core.Error{Command: "agents.start", Details: "agents.toolNotFound"}, true},
		{&core.Error{Command: "agents.start", Details: "agents.launchFailed"}, false},
		{context.DeadlineExceeded, false},
	}
	for _, c := range cases {
		if got := agentToolMissing(c.err); got != c.want {
			t.Errorf("agentToolMissing(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

func TestAMissingAgentCLILeadsToItsPluginInPlugins(t *testing.T) {
	conversation := sampleAgentConversation()
	h := showAgentConversation(t, conversation)
	agent := conversation.agent
	h.app.agentsView.starting = true
	h.app.finishConversationStart(h.app.project, agent, "", 0, false, fmt.Errorf("resolve: %w", &toolchain.UnavailableError{Tool: agent.Tool, Code: "toolchain.notFound"}))
	if h.app.agentsView.starting {
		t.Fatal("a failed start still shows as starting")
	}
	if len(h.app.notifications.list) == 0 {
		t.Fatal("a missing CLI was not reported")
	}
	entry := h.app.notifications.list[0]
	want := i18n.SharedFormat(i18n.English, "desktop.agents.cliMissing", map[string]string{"agent": agent.DisplayName})
	if entry.text != want || entry.actLabel != i18n.Shared(i18n.English, "desktop.agents.cliOpenPlugins") || entry.act == nil {
		t.Fatalf("notification = %q with %q, want %q with the Plugins action", entry.text, entry.actLabel, want)
	}
	if entry.detail != i18n.Shared(i18n.English, "desktop.agents.cliMissingDetail") {
		t.Fatalf("notification detail = %q, want the explanation of the Plugins action", entry.detail)
	}

	h.app.finishConversationStart(h.app.project, agent, "", 0, false, &toolchain.UnavailableError{Terminal: true, Tool: agent.Tool, Code: "toolchain.pinnedUnavailable"})
	if entry := h.app.notifications.list[0]; entry.act != nil || entry.text == want {
		t.Fatalf("a refused pinned CLI was reported as missing: %q", entry.text)
	}
}
