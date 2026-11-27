package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// The two channels share one settings file. Moving to the other channel keeps the settings as
// they are when this channel is left, and switching back to a channel can bring back the
// settings kept when Lithe last left it instead of keeping the current ones.
//
// The kept settings are copies of settings.json, byte for byte, in update-snapshots in the
// preferences directory, which the store owns; never in the application, which is read-only
// at run time and whose bytes a delta update is made from. A copy is named after the channel
// left, the version that left it and when, in UTC: stable-0.7.0-20261115100000.json. The
// newest updateSnapshotsKept copies are kept and older ones deleted.
//
// Restoring needs the new build: the one installing it has a settings format the new build may
// not share. When the user asked to restore, the install leaves pendingRestoreFile, naming the
// channel and version it installs and the copy to restore; an install that fails removes it.
// The first window of the next launch reads it before the settings, restores the copy when it
// is that channel and version, and removes it either way, so a launch of another build never
// restores. The copy is restored as it was kept except for the update settings, which stay as
// they are now: the copy chose the channel Lithe was leaving.

const (
	// updateSnapshotsDir is the directory of the kept settings, in the preferences directory.
	updateSnapshotsDir = "update-snapshots"
	// updateSnapshotsKept is how many copies are kept.
	updateSnapshotsKept = 5
	// pendingRestoreFile names, in updateSnapshotsDir, the copy the next launch restores.
	pendingRestoreFile = "pending-restore.json"
	// updateSnapshotStamp is the time in a copy's name.
	updateSnapshotStamp = "20060102150405"
)

// updateSettingsKeys are the settings a restored copy leaves as they are now, and
// updateChannelKeys the ones it drops, the switch the copy was kept for, so the restored build
// follows its own channel.
var (
	updateSettingsKeys = []string{"updatesManual", "updatesCheckedAt", "updateSources", "updateSkipped", "unknownSettingsNoticed"}
	updateChannelKeys  = []string{"updateChannel", "updateReturnNow", "updateRestore"}
)

// pendingRestore is what pendingRestoreFile holds.
type pendingRestore struct {
	Channel  string `json:"channel"`
	Version  string `json:"version"`
	Snapshot string `json:"snapshot"`
}

// updateSnapshotStore is the store of the kept settings, nil for a window without a store.
func (a *App) updateSnapshotStore() *store.Store {
	if a.store == nil {
		return nil
	}
	return store.At(filepath.Join(a.store.Dir(), updateSnapshotsDir))
}

// snapshotChannel is the channel a copy's name says it kept, and its time, or false for a file
// that is not a copy.
func snapshotChannel(name string) (channel, stamp string, ok bool) {
	base, found := strings.CutSuffix(name, ".json")
	first, last := strings.Index(base, "-"), strings.LastIndex(base, "-")
	if !found || first <= 0 || last <= first {
		return "", "", false
	}
	channel, stamp = buildinfo.KnownChannel(base[:first]), base[last+1:]
	if _, err := time.Parse(updateSnapshotStamp, stamp); err != nil || channel == "" {
		return "", "", false
	}
	return channel, stamp, true
}

// updateSnapshotFiles are the copies kept, newest first.
func updateSnapshotFiles(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var names []string
	for _, entry := range entries {
		if _, _, ok := snapshotChannel(entry.Name()); ok && entry.Type().IsRegular() {
			names = append(names, entry.Name())
		}
	}
	slices.SortFunc(names, func(x, y string) int {
		_, sx, _ := snapshotChannel(x)
		_, sy, _ := snapshotChannel(y)
		return strings.Compare(sy, sx)
	})
	return names
}

// updateSnapshots is the newest copy of each channel.
func (a *App) updateSnapshots() map[string]string {
	kept := a.updateSnapshotStore()
	newest := map[string]string{}
	if kept == nil {
		return newest
	}
	for _, name := range updateSnapshotFiles(kept.Dir()) {
		if channel, _, _ := snapshotChannel(name); newest[channel] == "" {
			newest[channel] = name
		}
	}
	return newest
}

// keepSettingsForSwitch keeps the settings as the installed channel leaves them, before the
// release of channel at version replaces the build. restore leaves pendingRestoreFile for the
// new build to bring back the copy kept when Lithe last left channel. A copy that cannot be
// kept is logged and the update goes on; a restore that cannot be prepared fails the update,
// since the user asked for it.
func (a *App) keepSettingsForSwitch(ctx context.Context, batch *settingsSaveBatch, channel, version string, restore bool) error {
	kept := a.updateSnapshotStore()
	if kept == nil {
		return nil
	}
	u := a.updates
	u.mu.Lock()
	installed, restoring := u.installed, u.snapshots[channel]
	u.mu.Unlock()
	if err := batch.wait(ctx); err != nil {
		a.backgroundFailedIn(ctx, "update_snapshot", documentLogError(err))
	} else if data, err := os.ReadFile(a.store.Path(settingsFile)); err != nil {
		a.backgroundFailedIn(ctx, "update_snapshot", err)
	} else {
		name := installed + "-" + a.version + "-" + time.Now().UTC().Format(updateSnapshotStamp) + ".json"
		if err := kept.WriteFile(name, data); err != nil {
			a.backgroundFailedIn(ctx, "update_snapshot", err)
		} else {
			a.pruneUpdateSnapshots(ctx, kept, restoring)
			u.mu.Lock()
			u.snapshots[installed] = name
			u.mu.Unlock()
		}
	}
	if !restore || restoring == "" {
		return nil
	}
	marker, err := json.Marshal(pendingRestore{Channel: channel, Version: version, Snapshot: restoring})
	if err != nil {
		return err
	}
	return kept.WriteFile(pendingRestoreFile, marker)
}

// pruneUpdateSnapshots deletes all but the newest updateSnapshotsKept copies, never the one a
// restore is about to use.
func (a *App) pruneUpdateSnapshots(ctx context.Context, kept *store.Store, keep string) {
	for i, name := range updateSnapshotFiles(kept.Dir()) {
		if i < updateSnapshotsKept || name == keep {
			continue
		}
		if err := kept.Remove(name); err != nil {
			a.backgroundFailedIn(ctx, "update_snapshot", err)
		}
	}
}

// dropPendingRestore removes the restore an install that failed prepared.
func (a *App) dropPendingRestore() {
	if kept := a.updateSnapshotStore(); kept != nil {
		if err := kept.Remove(pendingRestoreFile); err != nil {
			a.backgroundFailed("update_snapshot", err)
		}
	}
}

// restorePendingSettings restores the copy pendingRestoreFile names into the settings of
// preferences, when the running build is the channel and version it was left for, and removes
// the file. It runs before the first window reads the settings. restored says the settings
// were replaced.
func restorePendingSettings(preferences *store.Store, installed, version string) (restored bool, err error) {
	if preferences == nil {
		return false, nil
	}
	kept := store.At(filepath.Join(preferences.Dir(), updateSnapshotsDir))
	data, err := os.ReadFile(kept.Path(pendingRestoreFile))
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	removeErr := kept.Remove(pendingRestoreFile)
	var pending pendingRestore
	if err := json.Unmarshal(data, &pending); err != nil {
		return false, errors.Join(err, removeErr)
	}
	if installed == "" || pending.Channel != installed || pending.Version != version {
		return false, removeErr
	}
	if _, _, ok := snapshotChannel(pending.Snapshot); !ok || filepath.Base(pending.Snapshot) != pending.Snapshot {
		return false, errors.Join(errors.New("update snapshot: the restore names no kept copy"), removeErr)
	}
	snapshot, err := os.ReadFile(kept.Path(pending.Snapshot))
	if err != nil {
		return false, errors.Join(err, removeErr)
	}
	merged, err := restoredSettings(snapshot, preferences.Path(settingsFile))
	if err != nil {
		return false, errors.Join(err, removeErr)
	}
	if err := preferences.WriteFile(settingsFile, merged); err != nil {
		return false, errors.Join(err, removeErr)
	}
	return true, removeErr
}

// restoredSettings is the kept copy with the update settings of the current file at path, and
// without the switch the copy chose.
func restoredSettings(snapshot []byte, path string) ([]byte, error) {
	var restored map[string]json.RawMessage
	if err := json.Unmarshal(snapshot, &restored); err != nil {
		return nil, err
	}
	current := map[string]json.RawMessage{}
	if data, err := os.ReadFile(path); err == nil {
		// A current file that does not decode has no update settings worth keeping.
		_ = json.Unmarshal(data, &current)
	}
	for _, key := range updateChannelKeys {
		delete(restored, key)
	}
	for _, key := range updateSettingsKeys {
		if value, ok := current[key]; ok {
			restored[key] = value
		} else {
			delete(restored, key)
		}
	}
	return json.MarshalIndent(restored, "", "  ")
}
