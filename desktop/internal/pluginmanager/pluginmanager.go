// Package pluginmanager is the one place the workbench asks about installed
// plugins.
//
// It owns no policy of its own: extracting and installing belongs to pluginpkg,
// approving to plugintrust, storing enablement choices to pluginstate, and the
// lifecycle that spans them to Core (plugins.installed.lifecycle) — which plugin
// is enabled, what confirming an install, enabling, disabling and uninstalling
// do, and in which order. The manager hands Core the installed versions and the
// choices, and carries out the steps it gets back.
package pluginmanager

import (
	"context"
	"errors"
	"fmt"
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
func (m *Manager) Apply(ctx context.Context, action core.PluginLifecycleAction, id string, stop func() error) (bool, error) {
	_, plan, err := m.plan(ctx, action, id)
	if err != nil {
		return false, err
	}
	if plan.Rejection == core.PluginNotInstalled {
		return false, fmt.Errorf("%w: %s", ErrUnknownPlugin, id)
	}
	if plan.Rejection != "" {
		return false, fmt.Errorf("the plugin lifecycle of %s was refused: %s", id, plan.Rejection)
	}
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
		}
	}
	return plan.Changed, errors.Join(failures...)
}

// SetEnabled records the user turning an installed plugin on or off. It stops
// nothing; pluginservice.Service.Disable also stops what a disabled plugin runs.
func (m *Manager) SetEnabled(id string, enabled bool) error {
	action := core.PluginDisable
	if enabled {
		action = core.PluginEnable
	}
	ctx, cancel := context.WithTimeout(context.Background(), planTimeout)
	defer cancel()
	_, err := m.Apply(ctx, action, id, nil)
	return err
}

// EnableInstalled records that the user confirmed installing plugin id, which
// enables it unless the user already chose to enable or disable it, and reports
// whether it changed the choice.
func (m *Manager) EnableInstalled(id string) (bool, error) {
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
		request.Installed = append(request.Installed, core.PluginInstalledVersion{PluginID: entry.ID, Version: entry.Version})
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
