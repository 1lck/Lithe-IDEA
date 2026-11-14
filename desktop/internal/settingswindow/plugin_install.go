package settingswindow

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/vivaui/viva/ui"
)

// PluginInstallFeedback is tied to the settings window that started the request.
type PluginInstallFeedback struct {
	Context context.Context
	// Progress and Preparing publish transport progress and the local I/O stage.
	Progress  func(marketplace.ArchiveProgress)
	Preparing func()
	// Review accepts a verified reusable approval, or publishes the complete
	// review and waits for the user's decision.
	Review func(version string, review plugintrust.Review, reused bool) bool
	// Finish publishes the outcome after preparation or installation.
	Finish func(failed bool)
	// Failure supplies a native I/O error for localized recovery guidance.
	Failure func(error)
}

type pluginInstallReview struct {
	version     string
	permissions []string
	programs    []string
}

type pluginInstallProgress struct {
	marketplace.ArchiveProgress
	preparing bool
}

type pluginInstallFailure struct{ err error }

type pluginInstallOutcome uint32

const (
	pluginInstallPending pluginInstallOutcome = iota
	pluginInstallSucceeded
	pluginInstallFailed
)

const pluginReviewMaxDetailsHeight = 210

type pluginInstallDialog struct {
	name        string
	version     string
	marketplace bool
	download    func()
	retry       func()
	failure     atomic.Pointer[pluginInstallFailure]
	expanded    bool
	open        bool
	cancel      context.CancelFunc
	approved    chan struct{}
	review      atomic.Pointer[pluginInstallReview]
	progress    atomic.Pointer[pluginInstallProgress]
	outcome     atomic.Uint32
	details     ui.ListState
}

func (w *window) startMarketplaceInstall(plugin core.MarketplacePlugin) {
	feedback := w.startPluginInstall(plugin.Name, true)
	w.install.version = plugin.Availability.Version
	w.install.download = func() { w.ctrl.opts.InstallPlugin(plugin, feedback) }
	w.install.retry = func() {
		w.startMarketplaceInstall(plugin)
		start := w.install.download
		w.install.download = nil
		start()
	}
}

func (w *window) startPluginInstall(name string, fromMarketplace bool) PluginInstallFeedback {
	w.dismissPluginInstall()
	ctx, cancel := context.WithCancel(context.Background())
	dialog := &pluginInstallDialog{
		name: name, marketplace: fromMarketplace, open: true, cancel: cancel, approved: make(chan struct{}),
	}
	w.install = dialog
	return PluginInstallFeedback{
		Context: ctx,
		Progress: func(progress marketplace.ArchiveProgress) {
			dialog.progress.Store(&pluginInstallProgress{ArchiveProgress: progress})
			w.inv.Invalidate()
		},
		Preparing: func() {
			dialog.progress.Store(&pluginInstallProgress{preparing: true})
			w.inv.Invalidate()
		},
		Review: func(version string, review plugintrust.Review, reused bool) bool {
			if ctx.Err() != nil {
				return false
			}
			if fromMarketplace && reused {
				close(dialog.approved)
				w.inv.Invalidate()
				return true
			}
			programs := make([]string, len(review.Programs))
			for index, program := range review.Programs {
				programs[index] = plugintrust.CompactProgram(program)
			}
			dialog.review.Store(&pluginInstallReview{version, review.Permissions, programs})
			w.inv.Invalidate()
			select {
			case <-dialog.approved:
				return true
			case <-ctx.Done():
				// Closing Settings after clicking Install must not revoke approval.
				select {
				case <-dialog.approved:
					return true
				default:
					return false
				}
			}
		},
		Failure: func(err error) { dialog.failure.Store(&pluginInstallFailure{err}); w.inv.Invalidate() },
		Finish: func(failed bool) {
			outcome := pluginInstallSucceeded
			if failed {
				outcome = pluginInstallFailed
			}
			dialog.outcome.Store(uint32(outcome))
			w.inv.Invalidate()
		},
	}
}

func (w *window) dismissPluginInstall() {
	if dialog := w.install; dialog != nil {
		dialog.cancel()
		w.install = nil
	}
}

func (w *window) pluginInstallModal(c ui.C) {
	dialog := w.install
	if dialog == nil {
		return
	}
	language := w.marketLanguage()
	var committing bool
	select {
	case <-dialog.approved:
		committing = true
	default:
	}
	outcome := pluginInstallOutcome(dialog.outcome.Load())

	review := dialog.review.Load()
	description := dialog.name
	version := dialog.version
	if review != nil {
		version = review.version
	}
	if version != "" {
		description += " · " + version
	}
	confirmed, cancelled, downloadConfirmed, retried := false, false, false, false
	title := i18n.Shared(language, "desktop.marketplace.reviewTitle")
	if dialog.marketplace && review == nil && !committing && outcome != pluginInstallFailed {
		title = i18n.Shared(language, "desktop.marketplace.downloadTitle")
	}
	if committing {
		title = i18n.Shared(language, "desktop.marketplace.installTitle")
	}
	if outcome == pluginInstallSucceeded {
		title = i18n.Shared(language, "desktop.marketplace.installComplete")
	}
	if outcome == pluginInstallFailed {
		title = i18n.Shared(language, "desktop.marketplace.installFailed")
	}
	closed := ui.ModalWith(c, &dialog.open, title,
		ui.ModalSpec{Width: 620, Description: description}, func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				switch {
				case outcome == pluginInstallSucceeded:
					ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.installCompleteHelp"))
				case dialog.download != nil:
					ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.downloadPrompt"))
				case outcome == pluginInstallFailed:
					ui.Wrap(c, pluginInstallFailureText(language, dialog.failure.Load())).Color(w.pal.danger)
				case review != nil && !committing:
					ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.reviewConsent"))
					shown := *review
					if len(review.programs) > 0 {
						label := i18n.SharedFormat(language, "desktop.marketplace.programDetails", map[string]string{"count": strconv.Itoa(len(review.programs))})
						if ui.Button(c, label).Outline().Clicked() {
							dialog.expanded = !dialog.expanded
						}
						if !dialog.expanded {
							shown.programs = nil
						}
					}
					pluginInstallReviewBody(c, language, &dialog.details, &shown)
				default:
					label := i18n.Shared(language, "native.loading")
					progress := dialog.progress.Load()
					determinate := false
					var fraction float32
					switch {
					case committing:
						label = i18n.Shared(language, "settings.general.installing")
					case progress != nil && progress.preparing:
						label = i18n.Shared(language, "desktop.marketplace.verifying")
					case progress != nil && progress.Total > 0:
						label = i18n.SharedFormat(language, "desktop.marketplace.downloadProgress", map[string]string{
							"received": fmt.Sprintf("%.1f", float64(progress.Received)/(1<<20)),
							"total":    fmt.Sprintf("%.1f", float64(progress.Total)/(1<<20)),
						})
						determinate = true
						fraction = float32(progress.Received) / float32(progress.Total)
					case progress != nil:
						label = i18n.SharedFormat(language, "desktop.marketplace.downloadReceived", map[string]string{
							"received": fmt.Sprintf("%.1f", float64(progress.Received)/(1<<20)),
						})
					case dialog.marketplace:
						label = i18n.Shared(language, "desktop.marketplace.connecting")
					}
					ui.Column(c).FillWidth().Gap(8).Children(func() {
						ui.Text(c, label)
						if determinate {
							ui.Progress(c, fraction).FillWidth()
						} else {
							ui.Progress(c, 0).Indeterminate().FillWidth()
						}
					})
				}
			})
		}, func() {
			if outcome == pluginInstallSucceeded {
				cancelled = ui.Button(c, i18n.Shared(language, "ui.done")).Clicked()
				return
			}
			if outcome == pluginInstallFailed {
				cancelled = ui.Button(c, i18n.Shared(language, "ui.close")).Outline().Clicked()
				retried = ui.Button(c, i18n.Shared(language, "ui.retry")).Disabled(dialog.retry == nil).Clicked()
				return
			}
			if committing {
				return
			}
			cancelled = ui.Button(c, i18n.Shared(language, "desktop.marketplace.cancel")).Outline().Clicked()
			if dialog.download != nil {
				downloadConfirmed = ui.Button(c, i18n.Shared(language, "native.download")).AutoFocus().Clicked()
			} else if review != nil {
				confirmed = ui.Button(c, i18n.Shared(language, "desktop.marketplace.confirmInstall")).AutoFocus().Clicked()
			}
		})
	switch {
	case retried:
		c.After(func() {
			if w.install == dialog && dialog.retry != nil {
				dialog.retry()
			}
		})
	case downloadConfirmed:
		c.After(func() {
			if w.install == dialog && dialog.download != nil {
				start := dialog.download
				dialog.download = nil
				start()
			}
		})
	case confirmed:
		c.After(func() {
			close(dialog.approved)
		})
	case closed || cancelled:
		c.After(w.dismissPluginInstall)
	}
}

func pluginInstallReviewBody(c ui.C, language i18n.Language, details *ui.ListState, review *pluginInstallReview) {
	ui.Column(c).FillWidth().Gap(8).Children(func() {
		permissions := i18n.Shared(language, "desktop.marketplace.reviewPermissions")
		if len(review.permissions) == 0 && len(review.programs) == 0 {
			ui.Text(c, permissions).FontSize(13).Bold()
			ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.reviewEmpty")).FontSize(12).Muted()
			return
		}
		programs := i18n.Shared(language, "desktop.marketplace.reviewPrograms")
		programHeading := 1 + len(review.permissions)
		rows := programHeading
		if len(review.programs) > 0 {
			rows += 1 + len(review.programs)
		}
		details.Label = func(index int) string {
			switch {
			case index == 0:
				return permissions
			case index < programHeading:
				return review.permissions[index-1]
			case index == programHeading:
				return programs
			default:
				return review.programs[index-programHeading-1]
			}
		}
		ui.List(c, details, rows, func(row ui.ListRow) {
			row.Element.PadY(3).PadRight(12).Children(func() {
				label := details.Label(row.Index)
				switch {
				case row.Index == 0 || row.Index == programHeading:
					ui.Text(row.C, label).FontSize(13).Bold()
				case row.Index < programHeading:
					description := permissionDescription(language, label)
					if description != "" {
						ui.Wrap(row.C, description).FontSize(12).FillWidth()
					}
					ui.Wrap(row.C, label).FontSize(11).Mono().Muted().FillWidth()
				default:
					ui.Wrap(row.C, label).FontSize(11).Mono().Muted().FillWidth()
				}
			})
		}).Label(i18n.Shared(language, "desktop.marketplace.reviewTitle")).FillWidth().MaxHeight(pluginReviewMaxDetailsHeight)
	})
}

// pluginInstallFailureText presents native failures without exposing URLs or paths.
func pluginInstallFailureText(language i18n.Language, failure *pluginInstallFailure) string {
	if failure == nil {
		return i18n.Shared(language, "desktop.marketplace.failureHelp")
	}
	var network net.Error
	switch {
	case errors.Is(failure.err, context.DeadlineExceeded):
		return i18n.Shared(language, "desktop.marketplace.failureTimeout")
	case errors.Is(failure.err, marketplace.ErrArchiveChecksum):
		return i18n.Shared(language, "desktop.marketplace.failureChecksum")
	case errors.As(failure.err, &network):
		return i18n.Shared(language, "desktop.marketplace.failureNetwork")
	case errors.Is(failure.err, os.ErrPermission):
		return i18n.Shared(language, "desktop.marketplace.failurePermission")
	default:
		return i18n.Shared(language, "desktop.marketplace.failureHelp")
	}
}

func (w *window) startLocalPluginInstall(path string) {
	feedback := w.startPluginInstall(filepath.Base(path), false)
	w.install.retry = func() { w.startLocalPluginInstall(path) }
	w.ctrl.opts.InstallPluginFromFile(path, feedback)
}
