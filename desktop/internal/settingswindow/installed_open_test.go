package settingswindow

import (
	"context"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/vivaui/viva/app"
)

const (
	installedOpenFirst = "dev.lithe.test.first"
	installedOpenAgent = "dev.lithe.test.agent-cli"
)

// agentCommands is an agent plugin whose CLI, agent-cli, an installer provides.
type agentCommands struct{}

func (agentCommands) Missing(_ context.Context, pluginID string) ([]MissingCommand, error) {
	if pluginID != installedOpenAgent {
		return nil, nil
	}
	return []MissingCommand{{Kind: CapabilityAgent, ID: "example", Commands: []string{"agent-cli"}, Installer: "agent-cli", Tool: "npm"}}, nil
}

func (agentCommands) Offer(context.Context, string, string) (CommandInstallOffer, error) {
	return CommandInstallOffer{}, nil
}

func (agentCommands) Install(context.Context, string, string, string, func(string), func(pluginruntime.Progress)) (string, error) {
	return "", nil
}

// installedOpenWindow lists two plugins, the agent's second, on the Overview of the first.
func installedOpenWindow(current Values) *window {
	facts := []PluginFacts{
		{
			ID: installedOpenFirst, Name: "A First Plugin", Vendor: "Test", Version: "1.0.0", Source: PluginSourceDisk,
			Capabilities: []PluginCapability{{Kind: CapabilityCommand, ID: "hello", Title: "First Command"}},
		},
		{
			ID: installedOpenAgent, Name: "B Agent Plugin", Vendor: "Test", Version: "1.0.0", Source: PluginSourceDisk,
			Permissions:  []string{"agents.run", "commands.install"},
			Capabilities: []PluginCapability{{Kind: CapabilityAgent, ID: "example", Title: "Example Agent"}},
		},
	}
	w := newWindow(NewController(Options{
		Language:         func() i18n.Language { return i18n.English },
		Marketplace:      func(context.Context) (marketplace.Snapshot, error) { return marketplace.Snapshot{}, nil },
		InstalledPlugins: func() []PluginFacts { return facts },
		PluginState: func(string) PluginState {
			return PluginState{Installed: true, Version: "1.0.0", Enabled: true}
		},
		CommandInstalls: agentCommands{},
	}), current)
	w.sess.page = pagePlugins
	return w
}

func TestInstalledPluginOpensOnItsFeaturesWithTheAgentCLIToInstall(t *testing.T) {
	agent := installedOpenAgent
	w := installedOpenWindow(Values{InstalledPlugin: &agent})
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	missing := i18n.SharedFormat(i18n.English, "desktop.plugins.commandMissing", map[string]string{"commands": "agent-cli"})
	d.until("the agent card to report its missing CLI", func() bool {
		return d.text("Example Agent") && d.text(missing)
	})
	if !d.text(i18n.Shared(i18n.English, "desktop.plugins.capabilityAgent")) {
		t.Fatal("the agent card has no kind label")
	}
	if _, ok := d.find(i18n.Shared(i18n.English, "desktop.marketplace.install")); !ok {
		t.Fatal("the agent card offers no install")
	}
}

func TestOpenWindowSwitchesToTheRequestedInstalledPlugin(t *testing.T) {
	w := installedOpenWindow(Values{})
	w.pluginTab = pluginTabInstalled
	w.installed.selected, w.installed.query = installedOpenFirst, "First"
	d := openWindow(t, w, func(config *app.Config) { config.Width, config.Height = 1100, 800 })
	d.until("the first plugin", func() bool { return d.text("A First Plugin") })

	w.requestInstalled(installedOpenAgent)
	missing := i18n.SharedFormat(i18n.English, "desktop.plugins.commandMissing", map[string]string{"commands": "agent-cli"})
	d.until("the requested plugin's Features", func() bool { return d.text("Example Agent") && d.text(missing) })
	if w.installed.query != "" || w.installed.selected != installedOpenAgent || w.installed.tab != installedFeatures {
		t.Fatalf("installed = query %q, selected %q, tab %d", w.installed.query, w.installed.selected, w.installed.tab)
	}
}
