package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// runConfigDirectory holds every document a run configuration edit changes:
// `.lithe/run/configurations.yaml` (project), `.lithe/run/local.yaml` (this
// machine) and the plugin documents under `.lithe/run/plugin/`. Core reads them
// when it resolves and never writes them; the host applies the changes Core returns.
const (
	runConfigDirectory = ".lithe/"
	// runConfigMaximumBytes bounds each document the host captures and publishes.
	runConfigMaximumBytes = 4 << 20
	// runConfigRollbackTimeout bounds restoring the files a failed transaction already changed.
	runConfigRollbackTimeout = 5 * time.Second
)

// errRunConfigChangePath refuses a change outside the workspace's `.lithe` directory.
var errRunConfigChangePath = errors.New("run configuration change outside .lithe")

// runConfigFile is one change of a transaction with the file as it was captured.
type runConfigFile struct {
	change   core.RunConfigChange
	snapshot configfile.Snapshot
}

// backgroundRunConfig captures the source of an edit before the window queues it.
func (a *App) backgroundRunConfig(p *project, work func(context.Context) func(*App)) {
	connection, connected := captureWorkspaceConnection(p)
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		if !connected {
			disconnected, cancel := context.WithCancel(ctx)
			cancel()
			return work(disconnected)
		}
		return work(attachedWorkspaceContext(ctx, connection))
	})
}

// applyRunConfigChanges sends an edit to the same filesystem Core read.
func (a *App) applyRunConfigChanges(ctx context.Context, root string, changes []core.RunConfigChange) error {
	if len(changes) == 0 {
		return ctx.Err()
	}
	if core.RemoteWorkspaceOf(ctx) == nil {
		return applyRunConfigChanges(ctx, root, changes)
	}
	conflict, err := a.kernel.ApplyRemoteRunConfigurationChanges(ctx, root, changes)
	if conflict {
		return errors.Join(configfile.ErrConflict, err)
	}
	return err
}

// applyRunConfigChanges applies the file changes of one Core edit reply as one transaction.
// Every file must still hold the bytes Core computed its change from, else nothing is written
// and the result is configfile.ErrConflict. Writes come before deletions, so a document that
// replaces a legacy one exists before the legacy one goes. When a later file fails, the files
// already changed are restored to their captured bytes, unless something else changed them since.
func applyRunConfigChanges(ctx context.Context, root string, changes []core.RunConfigChange) error {
	files := make([]runConfigFile, 0, len(changes))
	seen := make(map[string]bool, len(changes))
	for _, change := range changes {
		if !runConfigChangePathAllowed(change.Path) || seen[change.Path] {
			return fmt.Errorf("%w: %s", errRunConfigChangePath, change.Path)
		}
		seen[change.Path] = true
		if change.Content != nil && len(*change.Content) > runConfigMaximumBytes {
			return configfile.ErrTooLarge
		}
		snapshot, err := configfile.Capture(ctx, root, change.Path, runConfigMaximumBytes)
		if err != nil {
			return err
		}
		if !runConfigBaseMatches(snapshot, change.BaseSHA256) {
			return configfile.ErrConflict
		}
		files = append(files, runConfigFile{change: change, snapshot: snapshot})
	}
	slices.SortStableFunc(files, func(a, b runConfigFile) int {
		return runConfigChangeOrder(a.change) - runConfigChangeOrder(b.change)
	})
	var committed []runConfigFile
	for index, file := range files {
		// Each publication rechecks the files still to come, so the transaction stops before
		// its first write when any of them changed, not halfway through.
		rest := files[index+1:]
		check := func() error {
			for _, other := range rest {
				if err := other.snapshot.Verify(ctx); err != nil {
					return err
				}
			}
			return nil
		}
		var done bool
		var err error
		if file.change.Content == nil {
			done, err = file.snapshot.Remove(ctx, check)
		} else {
			done, err = file.snapshot.Replace(ctx, []byte(*file.change.Content), check)
		}
		if done {
			committed = append(committed, file)
		}
		if err != nil {
			return errors.Join(err, rollbackRunConfigChanges(ctx, root, committed))
		}
	}
	return nil
}

// runConfigChangeOrder sorts writes before deletions.
func runConfigChangeOrder(change core.RunConfigChange) int {
	if change.Content == nil {
		return 1
	}
	return 0
}

// runConfigChangePathAllowed accepts a workspace-relative '/' path inside `.lithe`.
func runConfigChangePathAllowed(path string) bool {
	return strings.HasPrefix(path, runConfigDirectory) && !strings.Contains(path, "\\") &&
		filepath.IsLocal(filepath.FromSlash(path)) && filepath.ToSlash(filepath.Clean(filepath.FromSlash(path))) == path
}

// runConfigBaseMatches says the captured file is the one Core read: absent for a nil base,
// else bytes with that lowercase hex SHA-256.
func runConfigBaseMatches(snapshot configfile.Snapshot, base *string) bool {
	if base == nil {
		return !snapshot.Exists()
	}
	if !snapshot.Exists() {
		return false
	}
	sum := sha256.Sum256(snapshot.Bytes())
	return hex.EncodeToString(sum[:]) == *base
}

// rollbackRunConfigChanges restores the files a failed transaction changed, newest first. A
// file something else changed since is left alone and reported. The restore keeps running for
// a bounded time when the edit itself was cancelled.
func rollbackRunConfigChanges(ctx context.Context, root string, committed []runConfigFile) error {
	if len(committed) == 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), runConfigRollbackTimeout)
	defer cancel()
	var failures []error
	for _, file := range slices.Backward(committed) {
		current, err := configfile.Capture(ctx, root, file.change.Path, runConfigMaximumBytes)
		if err == nil && !runConfigHolds(current, file.change.Content) {
			err = configfile.ErrConflict
		}
		if err == nil {
			if file.snapshot.Exists() {
				_, err = current.Replace(ctx, file.snapshot.Bytes(), nil)
			} else {
				_, err = current.Remove(ctx, nil)
			}
		}
		if err != nil {
			failures = append(failures, fmt.Errorf("restore %s: %w", file.change.Path, err))
		}
	}
	return errors.Join(failures...)
}

// runConfigHolds says the file has content, or is absent for nil.
func runConfigHolds(snapshot configfile.Snapshot, content *string) bool {
	if content == nil {
		return !snapshot.Exists()
	}
	return snapshot.Exists() && string(snapshot.Bytes()) == *content
}

// runConfigPluginManifest is the part of a plugin.json the run configuration checks read.
type runConfigPluginManifest struct {
	ID               string          `json:"id"`
	DisplayName      string          `json:"displayName"`
	Version          string          `json:"version"`
	Repository       string          `json:"repository"`
	PluginAPIVersion *int            `json:"pluginAPIVersion"`
	Requires         json.RawMessage `json:"requires"`
}

// runConfigPlugins lists the enabled plugins for `runConfig.resolve` and the edit commands, so a
// configuration whose plugin is gone shows as unavailable and a written plugin document records
// the installed plugin. It is nil while the plugin host is not assembled, which skips those checks;
// a manifest that cannot be read leaves only that plugin out, and its configurations then show as
// unavailable.
func (a *App) runConfigPlugins(ctx context.Context) []core.RunInstalledPlugin {
	if a.plugins == nil {
		return nil
	}
	manifests, err := a.toolchainManifests(ctx)
	if err != nil {
		a.backgroundFailedIn(ctx, "run_config_plugins", err)
	}
	plugins := make([]core.RunInstalledPlugin, 0, len(manifests))
	for _, raw := range manifests {
		var manifest runConfigPluginManifest
		if json.Unmarshal(raw, &manifest) != nil || manifest.ID == "" || manifest.Version == "" {
			continue
		}
		plugin := core.RunInstalledPlugin{
			ID: manifest.ID, DisplayName: manifest.DisplayName, Version: manifest.Version,
			Repository: manifest.Repository, PluginAPIVersion: manifest.PluginAPIVersion,
		}
		if len(manifest.Requires) > 0 && string(manifest.Requires) != "null" {
			plugin.Requires = manifest.Requires
		}
		plugins = append(plugins, plugin)
	}
	return plugins
}
