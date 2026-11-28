package workbench

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui"
)

// This file finds an agent's CLI and leads the user to install it when it is missing.
//
// An agent's tool resolves through the toolchain layers every run uses. Discovery's command
// candidates also look in the directories the host installed the plugin's commands into (API-23
// command installers), so a CLI installed with the plugin's installer, for example with npm into
// the plugin's managed prefix, is found without being on PATH. When the CLI is still missing, the
// notification opens the plugin in Plugins, which lists the missing command and the installer the
// plugin offers; the host installs only after the user confirms it there.

// resolveAgentTool resolves the tool of the agent of plugin pluginID for the workspace root, ""
// for the global layers.
func (a *App) resolveAgentTool(ctx context.Context, root, pluginID, tool string) (pluginservice.RunExecutable, error) {
	if a.toolchainResolve != nil {
		return a.resolveRunTool(ctx, root, tool)
	}
	manifests, _, err := a.usableToolchainManifests(ctx, "toolchain_agent_discovery")
	if err != nil {
		return pluginservice.RunExecutable{}, err
	}
	options := a.toolchainOptions(ctx, root, manifests)
	options.Lookup = agentCommandLookup(a.installedCommands(), pluginID)
	selection, err := toolchain.Resolve(ctx, a.kernel, root, ".", tool, "", nil, manifests, options)
	if err != nil {
		return pluginservice.RunExecutable{}, err
	}
	return pluginservice.RunExecutable{Path: selection.Executable, Environment: applyToolchainSelection(nil, selection)}, nil
}

// agentCommandLookup is discovery's command lookup for the tool of an agent of plugin pluginID:
// PATH first, then the directories the plugin's commands were installed into. A hit outside PATH
// is canonical, as a PATH hit is, so it matches the tool definition's layouts.
func agentCommandLookup(store *pluginhost.CommandStore, pluginID string) toolchain.LookupFunc {
	if store == nil {
		return toolchain.LookupCommand
	}
	lookup := store.Lookup(pluginID, toolchain.LookupCommand)
	return func(command string) (string, error) {
		path, err := lookup(command)
		if err != nil {
			return "", err
		}
		return toolchain.CanonicalPath(path)
	}
}

// agentToolMissing reports whether err says the agent's CLI is not installed: discovery found no
// installation, or Core found no executable at the resolved path. A refused pinned or fixed
// installation is a choice of the user, not a missing CLI.
func agentToolMissing(err error) bool {
	var unavailable *toolchain.UnavailableError
	if errors.As(err, &unavailable) {
		return !unavailable.Terminal
	}
	var coreErr *core.Error
	return errors.As(err, &coreErr) && coreErr.Details == "agents.toolNotFound"
}

// notifyAgentToolMissing says the agent's CLI is missing; its button opens the agent's plugin in
// Plugins, where its command installer is offered. The toast has room for one short line, so the
// explanation goes in the detail that the notification history wraps.
func (a *App) notifyAgentToolMissing(agent agents.CatalogAgent) {
	lang := a.language()
	pluginID := agent.PluginID
	a.notifyActions(
		i18n.SharedFormat(lang, "desktop.agents.cliMissing", map[string]string{"agent": agent.DisplayName}),
		i18n.Shared(lang, "desktop.agents.cliMissingDetail"),
		ui.ToastError, i18n.Shared(lang, "desktop.agents.cliOpenPlugins"),
		func(a *App) { a.openInstalledPluginSettings(surfaceNotification, pluginID) },
		"", nil,
	)
}
