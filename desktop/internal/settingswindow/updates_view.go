package settingswindow

import (
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// UpdateStatus is what the updater is doing, as the Updates page shows it. The settings
// owner keeps it and the page reads it on every paint.
type UpdateStatus struct {
	// Configured is false for a build that has no update feed.
	Configured bool
	Checking   bool
	// Available is the newer version the feed offers, empty when none; NotesURL its
	// release notes.
	Available string
	NotesURL  string
	// UpToDate says the last check found nothing newer.
	UpToDate    bool
	Downloading bool
	// Progress is the share of the download done, 0 to 1.
	Progress float32
	// Ready says the verified download is waiting to be installed.
	Ready      bool
	Installing bool
	Failure    string
	// LastChecked is when the feed was last read successfully.
	LastChecked time.Time
}

// updatesPage is the Updates page: the running version, whether Lithe checks on its own,
// and the check, download and install of a newer version. Each step is the user's: a
// check finds a version, Download fetches and verifies it, and Install restarts into it.
func (w *window) updatesPage(c ui.C) {
	language := w.marketLanguage()
	opts := &w.ctrl.opts
	status := opts.UpdateStatus()
	label := func(key string) string { return i18n.Shared(language, key) }
	w.pageScroll(c, pageUpdates, func() {
		w.card(c, label("desktop.settings.updates.title"), label("desktop.settings.updates.help"), func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				ui.Text(c, w.text.App.Version(opts.Version)).FontSize(13).Color(w.pal.text)
				if !status.Configured {
					ui.Wrap(c, label("desktop.settings.updates.notConfigured")).FontSize(12).Color(w.pal.muted)
					return
				}
				auto := w.sess.values.AutoCheckUpdates
				if ui.Switch(c.Part("auto"), &auto, label("desktop.settings.updates.auto")).Changed() {
					w.sess.values.AutoCheckUpdates = auto
					if opts.SetAutoCheckUpdates != nil {
						opts.SetAutoCheckUpdates(auto)
					}
				}
				var line string
				switch {
				case status.Checking:
					line = label("desktop.settings.updates.checking")
				case status.Installing:
					line = label("desktop.settings.updates.installing")
				case status.Downloading:
					line = i18n.SharedFormat(language, "desktop.settings.updates.downloading", map[string]string{"percent": strconv.Itoa(int(status.Progress * 100))})
				case status.Ready:
					line = i18n.SharedFormat(language, "desktop.settings.updates.ready", map[string]string{"version": status.Available})
				case status.Available != "":
					line = i18n.SharedFormat(language, "desktop.settings.updates.available", map[string]string{"version": status.Available})
				case status.UpToDate:
					line = label("desktop.settings.updates.upToDate")
				}
				if line != "" {
					ui.Wrap(c, line).FontSize(12).Color(w.pal.text)
				}
				if status.Downloading {
					ui.Progress(c, status.Progress).FillWidth()
				}
				if status.Failure != "" {
					ui.Wrap(c, i18n.SharedFormat(language, "desktop.settings.updates.failed", map[string]string{"reason": status.Failure})).FontSize(12).Color(w.pal.danger)
				}
				if !status.LastChecked.IsZero() {
					ui.Text(c, i18n.SharedFormat(language, "desktop.settings.updates.lastChecked", map[string]string{"time": status.LastChecked.Local().Format("2006-01-02 15:04")})).FontSize(12).Color(w.pal.muted)
				}
				busy := status.Checking || status.Downloading || status.Installing
				ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
					if ui.Button(c.Part("check"), label("desktop.settings.updates.check")).Outline().Disabled(busy).Clicked() && opts.CheckForUpdates != nil {
						opts.CheckForUpdates()
					}
					if status.Available != "" && !status.Ready {
						if ui.Button(c.Part("download"), label("desktop.settings.updates.download")).Disabled(busy).Clicked() && opts.DownloadUpdate != nil {
							opts.DownloadUpdate()
						}
					}
					if status.Ready {
						if ui.Button(c.Part("install"), label("desktop.settings.updates.install")).Disabled(busy).Clicked() && opts.InstallUpdate != nil {
							opts.InstallUpdate()
						}
					}
					if status.NotesURL != "" && opts.OpenURL != nil {
						if ui.Button(c.Part("notes"), label("desktop.settings.updates.notes")).Ghost().Clicked() {
							opts.OpenURL(status.NotesURL)
						}
					}
				})
			})
		})
	})
}
