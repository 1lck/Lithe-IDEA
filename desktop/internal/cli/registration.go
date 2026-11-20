// Package cli installs an opt-in launcher in user data and edits the native shell's
// actual configuration. The installed application and unrelated shell content stay read-only.
package cli

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
)

var ErrUnsupportedShell = errors.New("unsupported login shell")
var ErrLauncherConflict = errors.New("CLI launcher is not managed by Lithe")

// State is a native read baseline, retained privately by the settings page until
// an explicit click. Apply rejects external edits rather than overwriting them.
type State struct {
	Shell, Target, Launcher string
	Installed, Registered   bool
	source                  nativeSource
	launcher                configfile.Snapshot
}

// Manager owns publication within this settings controller; reads never create files.
type Manager struct {
	mu                    sync.Mutex
	Kernel                *core.Client
	Directory, Executable string
	// Source is optional platform input for isolated integration tests.
	source func(context.Context) (nativeSource, error)
}

func New() *Manager { return &Manager{Kernel: core.NewClient()} }

func (m *Manager) paths() (string, string, error) {
	directory, executable := m.Directory, m.Executable
	if directory == "" {
		root, err := os.UserConfigDir()
		if err != nil {
			return "", "", err
		}
		directory = filepath.Join(root, "Lithe", "cli", "bin")
	}
	if executable == "" {
		var err error
		executable, err = installedpackage.Executable()
		if err != nil {
			return "", "", err
		}
	}
	return directory, executable, nil
}

func (m *Manager) Read(ctx context.Context) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.read(ctx)
}

func (m *Manager) read(ctx context.Context) (State, error) {
	directory, executable, err := m.paths()
	if err != nil {
		return State{}, err
	}
	read := readNativeSource
	if m.source != nil {
		read = m.source
	}
	source, err := read(ctx)
	if err != nil {
		return State{}, err
	}
	launcher, err := configfile.Capture(ctx, directory, launcherName, maximumSourceBytes)
	if err != nil {
		return State{}, err
	}
	edit, err := m.Kernel.EditCLIRegistration(ctx, source.shell, source.text, directory, executable, "inspect", string(launcher.Bytes()))
	if err != nil {
		return State{}, err
	}
	installed := edit.Installed && string(launcher.Bytes()) == edit.Launcher && launcherExecutable(launcher.Path())
	return State{Shell: source.shell, Target: source.target, Launcher: launcher.Path(), Installed: installed, Registered: edit.Installed, source: source, launcher: launcher}, nil
}

func (m *Manager) Apply(ctx context.Context, baseline State, install bool) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	directory, executable, err := m.paths()
	if err != nil {
		return State{}, err
	}
	if baseline.Launcher != filepath.Join(directory, launcherName) {
		return State{}, configfile.ErrConflict
	}
	if err := baseline.source.verify(ctx); err != nil {
		return State{}, err
	}
	action := "remove"
	if install {
		action = "install"
	}
	edit, err := m.Kernel.EditCLIRegistration(ctx, baseline.Shell, baseline.source.text, directory, executable, action, string(baseline.launcher.Bytes()))
	if err != nil {
		return State{}, err
	}
	if install {
		// Repair only our complete owned launcher, including after an app update or move.
		if baseline.launcher.Exists() && !edit.Owned {
			return State{}, ErrLauncherConflict
		}
		if _, err := baseline.launcher.Replace(ctx, []byte(edit.Launcher), func() error { return baseline.source.verify(ctx) }); err != nil {
			return State{}, err
		}
		if err := makeLauncherExecutable(baseline.Launcher); err != nil {
			return State{}, err
		}
	}
	if err := baseline.source.replace(ctx, edit.Source); err != nil {
		return State{}, err
	}
	if !install && baseline.launcher.Exists() && edit.Owned {
		if _, err := baseline.launcher.Remove(ctx, nil); err != nil {
			return State{}, err
		}
	}
	return m.read(ctx)
}
