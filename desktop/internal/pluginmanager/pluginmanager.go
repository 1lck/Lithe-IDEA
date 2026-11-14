// Package pluginmanager is the one place the workbench asks about installed
// plugins.
//
// It owns no policy of its own: extracting and installing belongs to pluginpkg,
// approving to plugintrust, storing enablement choices to pluginstate, and the
// lifecycle that spans them to Core (plugins.installed.lifecycle) — which plugin
// is enabled, what confirming an install, enabling, disabling and uninstalling
// do, and in which order. The manager hands Core the installed versions, the
// languages each one's manifest declares a language server for, and the choices,
// and carries out the steps it gets back. Core keeps one enabled plugin per
// language, so enabling a plugin can turn another off; the manager records that
// and reports it, and the caller stops that plugin's programs and tells the user.
package pluginmanager

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

// ErrUnknownPlugin reports a plugin that has no installed version.
var ErrUnknownPlugin = errors.New("plugin is not installed")

// planTimeout bounds one Core plan asked for without a caller's context. Core answers from
// the identities it is given, without reading a file.
const planTimeout = 5 * time.Second

// maxManifestBytes bounds the manifest read for its language servers; it is the limit the
// installer accepts, so a package on disk never exceeds it.
const maxManifestBytes = 8 << 20

// Kernel is the Core the manager asks for the lifecycle rules.
type Kernel interface {
	PlanPluginLifecycle(context.Context, core.PluginLifecycleRequest) (core.PluginLifecycle, error)
}

// Entry is one installed plugin version and whether its plugin is enabled.
type Entry struct {
	// Installed is the package on disk.
	Installed pluginpkg.Installed
	// Enabled is the plugin's enablement, not this version's.
	Enabled bool
}

// Displaced is a plugin a lifecycle action turned off because the action's plugin
// serves LanguageIDs too. Its choice is already recorded disabled; its programs
// still run until the caller stops them.
type Displaced struct {
	PluginID    string
	LanguageIDs []string
}

// Outcome is what a lifecycle action did beyond its own plugin.
type Outcome struct {
	// Changed says the action changed the choice for its plugin.
	Changed bool
	// Displaced are the plugins the action turned off, in plugin ID order.
	Displaced []Displaced
}

// Manager ties the installed packages to their approval records and enablement
// choices.
type Manager struct {
	kernel    Kernel
	root      string
	approvals *plugintrust.Store
	state     *pluginstate.Store
}

// New returns a manager for the plugin root root.
func New(kernel Kernel, root string, approvals *plugintrust.Store, state *pluginstate.Store) *Manager {
	return &Manager{kernel: kernel, root: root, approvals: approvals, state: state}
}

// Installed reports every installed version with its plugin's enablement.
func (m *Manager) Installed() ([]Entry, error) {
	ctx, cancel := context.WithTimeout(context.Background(), planTimeout)
	defer cancel()
	installed, plan, err := m.plan(ctx, "", "")
	if err != nil {
		return nil, err
	}
	enabled := make(map[string]bool, len(plan.Plugins))
	for _, plugin := range plan.Plugins {
		enabled[plugin.PluginID] = plugin.Enabled
	}
	entries := make([]Entry, 0, len(installed))
	for _, packageEntry := range installed {
		entries = append(entries, Entry{Installed: packageEntry, Enabled: enabled[packageEntry.ID]})
	}
	return entries, nil
}

// Apply carries out action on plugin id as Core plans it, and reports whether it
// changed the user's choice for the plugin. stop stops what the plugin runs and
// returns once it ended; nil means the caller runs nothing of the plugin.
//
// Steps run in Core's order and a failed one does not stop the rest, so a failure
// to clean up one record never leaves a half-removed package that still looks
// installed; every failure is returned for the caller to log. An approval is only
// forgotten once its version is gone, so the next installation of a version that
// could not be removed asks the user again.
func (m *Manager) Apply(ctx context.Context, action core.PluginLifecycleAction, id string, stop func() error) (Outcome, error) {
	_, plan, err := m.plan(ctx, action, id)
	if err != nil {
		return Outcome{}, err
	}
	if plan.Rejection == core.PluginNotInstalled {
		return Outcome{}, fmt.Errorf("%w: %s", ErrUnknownPlugin, id)
	}
	if plan.Rejection != "" {
		return Outcome{}, fmt.Errorf("the plugin lifecycle of %s was refused: %s", id, plan.Rejection)
	}
	outcome := Outcome{Changed: plan.Changed}
	var failures []error
	for _, step := range plan.Steps {
		switch step.Kind {
		case core.PluginRecordChoice:
			if err := m.state.SetEnabled(id, step.Enabled); err != nil {
				failures = append(failures, fmt.Errorf("record the enablement of %s: %w", id, err))
			}
		case core.PluginForgetChoice:
			if err := m.state.Forget(id); err != nil {
				failures = append(failures, fmt.Errorf("forget the enablement of %s: %w", id, err))
			}
		case core.PluginStopPrograms:
			if stop != nil {
				if err := stop(); err != nil {
					failures = append(failures, err)
				}
			}
		case core.PluginRemoveVersion:
			if err := pluginpkg.Uninstall(m.root, id, step.Version); err != nil {
				failures = append(failures, err)
				continue
			}
			if err := m.approvals.Forget(id, step.Version); err != nil {
				failures = append(failures, fmt.Errorf("forget the approval of %s %s: %w", id, step.Version, err))
			}
		case core.PluginRemoveState:
			if err := pluginpkg.RemoveState(m.root, id); err != nil {
				failures = append(failures, fmt.Errorf("remove the state of %s: %w", id, err))
			}
		case core.PluginDisplacePlugin:
			// Recorded before the caller stops the programs, as Disable does, so
			// nothing starts the displaced plugin again while it stops.
			if err := m.state.SetEnabled(step.PluginID, false); err != nil {
				failures = append(failures, fmt.Errorf("record that %s was turned off for %s: %w", step.PluginID, id, err))
			}
			outcome.Displaced = append(outcome.Displaced, Displaced{PluginID: step.PluginID, LanguageIDs: step.LanguageIDs})
		}
	}
	return outcome, errors.Join(failures...)
}

// SetEnabled records the user turning an installed plugin on or off. It stops
// nothing; pluginservice.Service.Disable also stops what a disabled plugin runs,
// and Enable reports the plugins enabling this one turned off.
func (m *Manager) SetEnabled(id string, enabled bool) error {
	if enabled {
		_, err := m.Enable(id)
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), planTimeout)
	defer cancel()
	_, err := m.Apply(ctx, core.PluginDisable, id, nil)
	return err
}

// Enable records the user turning an installed plugin on and reports the plugins
// it turned off because it serves one of their languages; their programs are the
// caller's to stop.
func (m *Manager) Enable(id string) ([]Displaced, error) {
	ctx, cancel := context.WithTimeout(context.Background(), planTimeout)
	defer cancel()
	outcome, err := m.Apply(ctx, core.PluginEnable, id, nil)
	return outcome.Displaced, err
}

// EnableInstalled records that the user confirmed installing plugin id, which
// enables it unless the user already chose to enable or disable it, and reports
// whether it changed the choice and which plugins it turned off.
func (m *Manager) EnableInstalled(id string) (Outcome, error) {
	ctx, cancel := context.WithTimeout(context.Background(), planTimeout)
	defer cancel()
	return m.Apply(ctx, core.PluginConfirmInstall, id, nil)
}

// plan lists the installed versions and the choices and asks Core for the plan of
// action on plugin id; an empty action only asks for enablement.
func (m *Manager) plan(ctx context.Context, action core.PluginLifecycleAction, id string) ([]pluginpkg.Installed, core.PluginLifecycle, error) {
	installed, err := pluginpkg.List(m.root)
	if err != nil {
		return nil, core.PluginLifecycle{}, err
	}
	choices, err := m.state.List()
	if err != nil {
		return nil, core.PluginLifecycle{}, err
	}
	request := core.PluginLifecycleRequest{Action: action, PluginID: id}
	for _, entry := range installed {
		request.Installed = append(request.Installed, core.PluginInstalledVersion{
			PluginID: entry.ID, Version: entry.Version, LanguageServers: languageServers(entry.Path),
		})
	}
	for _, choice := range choices {
		request.Choices = append(request.Choices, core.PluginEnablement{PluginID: choice.PluginID, Enabled: choice.Enabled})
	}
	plan, err := m.kernel.PlanPluginLifecycle(ctx, request)
	if err != nil {
		return nil, core.PluginLifecycle{}, fmt.Errorf("plan the plugin lifecycle: %w", err)
	}
	return installed, plan, nil
}

// Approval reports what the user approved when this version was installed: where
// the package came from, its digests, permissions and programs. A version without
// a record reports false; the plugin page shows its source as unknown.
func (m *Manager) Approval(id, version string) (plugintrust.Record, bool, error) {
	return m.approvals.Record(id, version)
}

// languageServers is the languageID of every language server the manifest in
// directory declares, in declaration order.
//
// A manifest that cannot be read or decoded serves nothing: the host cannot start
// that version's server either, and the paths that load the manifest to start it
// or register its languages report the failure.
func languageServers(directory string) []string {
	file, err := os.Open(filepath.Join(directory, pluginpkg.ManifestFile))
	if err != nil {
		// log-exempt: 同一次失败已经记录过：启动语言服务器与注册语言时读取同一份清单并报告失败
		return nil
	}
	defer file.Close()
	var manifest struct {
		LanguageServers []struct {
			LanguageID string `json:"languageID"`
		} `json:"languageServers"`
	}
	if err := json.NewDecoder(io.LimitReader(file, maxManifestBytes)).Decode(&manifest); err != nil {
		// log-exempt: 同一次失败已经记录过：启动语言服务器与注册语言时读取同一份清单并报告失败
		return nil
	}
	languages := make([]string, 0, len(manifest.LanguageServers))
	for _, server := range manifest.LanguageServers {
		languages = append(languages, server.LanguageID)
	}
	return languages
}
