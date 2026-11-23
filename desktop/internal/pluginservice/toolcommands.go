package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
)

// ToolCommand is one command a plugin declares under ui.commands. Core validated the
// manifest at install; the command opens one of the same plugin's tool windows.
type ToolCommand struct {
	PluginID string
	ID       string
	Title    string
	// ToolWindowID is the plugin's tool window the command opens.
	ToolWindowID string
	Order        int
	// Placements are the places the command is offered: commandPalette, toolbar or menu.
	Placements []string
}

// ToolCommands reads the commands of every enabled plugin, ordered like the tool windows. A broken
// manifest is reported without hiding the others.
func (s *Service) ToolCommands(ctx context.Context, entries []pluginmanager.Entry) ([]ToolCommand, error) {
	snapshot, readErr := s.ReadInstalled(ctx, entries)
	contributions, err := snapshot.ToolCommands()
	return contributions, errors.Join(readErr, err)
}

// ToolCommands reads its contribution sections from the same installed bytes.
func (snapshot InstalledSnapshot) ToolCommands() ([]ToolCommand, error) {
	var commands []ToolCommand
	var failures []error
	// Sort a copy of the headers so other consumers keep Core's selection order.
	selected := append([]installedManifest(nil), snapshot.manifests...)
	sort.Slice(selected, func(i, j int) bool { return selected[i].entry.Installed.ID < selected[j].entry.Installed.ID })
	for _, installed := range selected {
		entry, manifest := installed.entry, installed.manifest
		var declared struct {
			UI struct {
				Commands []struct {
					ID           string   `json:"id"`
					Title        string   `json:"title"`
					ToolWindowID string   `json:"toolWindowID"`
					Order        int      `json:"order"`
					Placements   []string `json:"placements"`
				} `json:"commands"`
			} `json:"ui"`
		}
		if err := json.Unmarshal(manifest, &declared); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		first := len(commands)
		for _, command := range declared.UI.Commands {
			if command.ID == "" {
				continue
			}
			commands = append(commands, ToolCommand{
				PluginID: entry.Installed.ID, ID: command.ID, Title: command.Title, ToolWindowID: command.ToolWindowID,
				Order: command.Order, Placements: command.Placements,
			})
		}
		own := commands[first:]
		sort.SliceStable(own, func(i, j int) bool {
			if own[i].Order != own[j].Order {
				return own[i].Order < own[j].Order
			}
			return own[i].ID < own[j].ID
		})
	}
	return commands, errors.Join(failures...)
}
