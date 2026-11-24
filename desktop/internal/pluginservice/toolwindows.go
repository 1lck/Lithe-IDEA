package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
)

// ToolWindow is one tool window a plugin declares under ui.toolWindows: a
// plain text window (`ui` 1) or a page of the plugin's package (`ui` 2).
type ToolWindow struct {
	PluginID string
	// PluginName is the plugin's display name, which the host's own text
	// about the window, such as a dialog title, names it by.
	PluginName string
	// Package is the installed package directory, read only.
	Package string
	// Manifest is the installed manifest, which Core validated at install
	// and validates again when a page of the window opens.
	Manifest json.RawMessage
	ID       string
	Title    string
	// Placement is the initial dock: "left", "bottom" or "right".
	Placement string
	Order     int
	// Text is the literal content of a text window.
	Text string
	// Web is the package-relative entry document of a web window.
	Web string
	// View is the backend view function that draws the window's body for each view event
	// (pluginview); empty for the other kinds.
	View string
	// IconHost names a host icon; Icon instead names read-only package resources.
	IconHost string
	Icon     pluginicons.Declaration
}

// ToolWindows reads the tool windows of every enabled plugin, ordered by
// plugin ID, then by the declared order and ID. A broken manifest is
// reported without hiding the others.
func (s *Service) ToolWindows(ctx context.Context, entries []pluginmanager.Entry) ([]ToolWindow, error) {
	snapshot, readErr := s.ReadInstalled(ctx, entries)
	contributions, err := snapshot.ToolWindows()
	return contributions, errors.Join(readErr, err)
}

// ToolWindows reads its contribution sections from the same installed bytes.
func (snapshot InstalledSnapshot) ToolWindows() ([]ToolWindow, error) {
	var windows []ToolWindow
	var failures []error
	// Sort a copy of the headers so other consumers keep Core's selection order.
	selected := append([]installedManifest(nil), snapshot.manifests...)
	sort.Slice(selected, func(i, j int) bool { return selected[i].entry.Installed.ID < selected[j].entry.Installed.ID })
	for _, installed := range selected {
		entry, manifest := installed.entry, installed.manifest
		var declared struct {
			DisplayName string `json:"displayName"`
			UI          struct {
				ToolWindows []struct {
					ID        string `json:"id"`
					Title     string `json:"title"`
					Placement string `json:"placement"`
					Order     int    `json:"order"`
					Text      string `json:"text"`
					View      *struct {
						Function string `json:"function"`
					} `json:"view"`
					Web *struct {
						Entry string `json:"entry"`
					} `json:"web"`
					Icon *struct {
						Host     string `json:"host"`
						Path     string `json:"path"`
						DarkPath string `json:"darkPath"`
						Mode     string `json:"mode"`
					} `json:"icon"`
				} `json:"toolWindows"`
			} `json:"ui"`
		}
		if err := json.Unmarshal(manifest, &declared); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		first := len(windows)
		for _, window := range declared.UI.ToolWindows {
			if window.ID == "" {
				failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, errors.New("a tool window has no id")))
				continue
			}
			declaredWindow := ToolWindow{
				PluginID: entry.Installed.ID, PluginName: declared.DisplayName, Package: entry.Installed.Path, Manifest: manifest,
				ID: window.ID, Title: window.Title, Placement: window.Placement, Order: window.Order, Text: window.Text,
			}
			if window.Web != nil {
				declaredWindow.Web = window.Web.Entry
			}
			if window.Icon != nil {
				declaredWindow.IconHost = window.Icon.Host
				declaredWindow.Icon = pluginicons.Declaration{
					Path: window.Icon.Path, DarkPath: window.Icon.DarkPath, Mode: window.Icon.Mode,
				}
			}
			if window.View != nil {
				declaredWindow.View = window.View.Function
			}
			windows = append(windows, declaredWindow)
		}
		own := windows[first:]
		sort.SliceStable(own, func(i, j int) bool {
			if own[i].Order != own[j].Order {
				return own[i].Order < own[j].Order
			}
			return own[i].ID < own[j].ID
		})
	}
	return windows, errors.Join(failures...)
}
