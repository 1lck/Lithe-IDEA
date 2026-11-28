package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
)

// agentHostMethods are the API-45 backend methods Core answers itself: write and report for a
// plugin with agents.native, usage for agents.usage.read. The host never receives them; it only
// lets a backend's start request advertise them.
var agentHostMethods = []string{
	pluginhost.MethodPrefix + "agents/write",
	pluginhost.MethodPrefix + "agents/report",
	pluginhost.MethodPrefix + "agents/usage",
}

// ErrAgentNotActivating reports an agent of a stopped backend whose manifest does not list
// onAgent:<agentID>, so using the agent must not start the backend.
var ErrAgentNotActivating = errors.New("the plugin's backend is stopped and does not activate on this agent")

// AgentPlugin is an enabled plugin that takes part in API-45: it declares agents or reads their
// usage.
type AgentPlugin struct {
	PluginID string
	// DisplayName is the manifest's name of the plugin.
	DisplayName string
	// Manifest is the installed manifest, passed to agents.configure as it is.
	Manifest json.RawMessage
	// Permissions are the permissions the manifest asks for; installing the plugin approved all
	// of them except agents.sessions.read, which the user grants per plugin in the settings.
	Permissions []string
	// Agents are the IDs of the agents the manifest declares.
	Agents []string
	// SessionRoots are the candidate session directories the agents declare, as written in the
	// manifest (${userHome} and ${env:NAME} unexpanded), for the consent the user gives.
	SessionRoots []string
	// Package is the installed package directory, read only; the agents' package icons are read
	// from it.
	Package string
	// Icons are the package icons the agents declare, by agent ID.
	Icons map[string]pluginicons.Declaration
}

// AgentPlugins lists the snapshot's plugins that declare agents or read their usage, sorted by
// plugin ID. A manifest that does not parse is reported and left out.
func (snapshot InstalledSnapshot) AgentPlugins() ([]AgentPlugin, error) {
	var plugins []AgentPlugin
	var failures []error
	for _, installed := range snapshot.manifests {
		var declared struct {
			DisplayName string   `json:"displayName"`
			Permissions []string `json:"permissions"`
			Agents      []struct {
				ID   string `json:"id"`
				Icon *struct {
					Path     string `json:"path"`
					DarkPath string `json:"darkPath"`
					Mode     string `json:"mode"`
				} `json:"icon"`
				SessionSources []struct {
					Roots []string `json:"roots"`
				} `json:"sessionSources"`
			} `json:"agents"`
		}
		if err := json.Unmarshal(installed.manifest, &declared); err != nil {
			failures = append(failures, fmt.Errorf("read agents of %s: %w", installed.entry.Installed.ID, err))
			continue
		}
		if !agents.UsesAgents(len(declared.Agents) > 0, declared.Permissions) {
			continue
		}
		ids := make([]string, 0, len(declared.Agents))
		var roots []string
		var icons map[string]pluginicons.Declaration
		for _, agent := range declared.Agents {
			ids = append(ids, agent.ID)
			if agent.Icon != nil && agent.Icon.Path != "" {
				if icons == nil {
					icons = map[string]pluginicons.Declaration{}
				}
				icons[agent.ID] = pluginicons.Declaration{Path: agent.Icon.Path, DarkPath: agent.Icon.DarkPath, Mode: agent.Icon.Mode}
			}
			for _, source := range agent.SessionSources {
				for _, root := range source.Roots {
					if !slices.Contains(roots, root) {
						roots = append(roots, root)
					}
				}
			}
		}
		plugins = append(plugins, AgentPlugin{
			PluginID:     installed.entry.Installed.ID,
			DisplayName:  declared.DisplayName,
			Manifest:     installed.manifest,
			Permissions:  declared.Permissions,
			Agents:       ids,
			SessionRoots: roots,
			Package:      installed.entry.Installed.Path,
			Icons:        icons,
		})
	}
	sort.Slice(plugins, func(i, j int) bool { return plugins[i].PluginID < plugins[j].PluginID })
	return plugins, errors.Join(failures...)
}

// EnsureAgentBackend starts the backend of a plugin whose agent the user is about to use and
// waits until it registered its functions, so Core can call its launch, scan and read
// functions. A stopped backend whose manifest does not activate on onAgent:<agentID> is not
// started.
func (s *Service) EnsureAgentBackend(ctx context.Context, pluginID, agentID string) error {
	if s == nil || s.Host == nil {
		return ErrBackendUnavailable
	}
	if s.Host.Running(pluginID) == nil {
		manifest, err := s.installedManifest(ctx, pluginID)
		if err != nil {
			return err
		}
		if !declaresBackend(manifest) || !declaredActivation(manifest, "onAgent:"+agentID) {
			return ErrAgentNotActivating
		}
	}
	_, err := s.Host.Functions(ctx, pluginID)
	return err
}
