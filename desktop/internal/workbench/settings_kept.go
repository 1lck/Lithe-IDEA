package workbench

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The stable channel and AutoBuild share one settings file, so the build that runs may meet
// settings only a newer build knows: keys it has no field for, or a known key holding a value of
// another shape. The store keeps them on every save (store.Store.Unknown), and this version
// ignores them. The first window says so once for each set of such keys, so that moving between
// channels does not look like settings were lost; the set it told about is saved
// (settings.UnknownSettingsNoticed), and the same set says nothing on the next launch.

// unknownSettingsNamed is how many of the kept keys the notice names.
const unknownSettingsNamed = 5

// noticeUnknownSettings tells, once per set, about the settings the file holds that this version
// does not read. It runs on the first window after the settings are loaded.
func (a *App) noticeUnknownSettings() {
	if a.store == nil {
		return
	}
	unknown := a.store.Unknown(settingsFile)
	fingerprint := unknownSettingsFingerprint(unknown)
	if fingerprint == a.settings.UnknownSettingsNoticed {
		return
	}
	a.settings.UnknownSettingsNoticed = fingerprint
	a.saveSettings()
	if len(unknown) == 0 {
		return
	}
	named := unknown
	if len(named) > unknownSettingsNamed {
		named = append(named[:unknownSettingsNamed:unknownSettingsNamed], "…")
	}
	a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.settings.unknownKept", map[string]string{
		"count": strconv.Itoa(len(unknown)),
		"keys":  strings.Join(named, ", "),
	}))
}

// unknownSettingsFingerprint names a set of kept keys in a few characters, empty for none.
func unknownSettingsFingerprint(keys []string) string {
	if len(keys) == 0 {
		return ""
	}
	sum := sha256.Sum256([]byte(strings.Join(keys, "\n")))
	return hex.EncodeToString(sum[:8])
}

// noticeUnreadableSettings explains the fallback while the original file is still in place.
func (a *App) noticeUnreadableSettings() {
	language := a.language()
	a.notifyActions(
		i18n.Shared(language, "desktop.settings.unreadable.title"),
		i18n.Shared(language, "desktop.settings.unreadable.detail"),
		ui.ToastWarning, "", nil, "", nil,
	)
}

// noticeSettingsBackup reports the actual path once the store has moved the original file.
func (a *App) noticeSettingsBackup(path string) {
	language := a.language()
	a.notifyActions(
		i18n.Shared(language, "desktop.settings.backup.title"),
		i18n.SharedFormat(language, "desktop.settings.backup.detail", map[string]string{"path": path}),
		ui.ToastInfo, "", nil, "", nil,
	)
}
