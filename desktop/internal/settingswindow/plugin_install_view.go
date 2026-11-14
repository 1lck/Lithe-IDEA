package settingswindow

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// PluginInstallStatus is an immutable view of a native transfer and package review.
// Token identifies the operation whose buttons are being answered, across windows.
type PluginInstallStatus struct {
	Token                                   uint64
	Busy, Review, Failed, Reused, Completed bool
	Name, Version, Phase, Failure           string
	Received, Total                         int64
	Permissions, Programs                   []string
}

// PluginInstallDialogState contains only viewport and disclosure state of one window.
type PluginInstallDialogState struct {
	open                      *bool
	token                     uint64
	details                   bool
	permissions, declarations ui.ListState
	lines                     []string
}

func (w *window) pluginInstallDialog(c ui.C) {
	if w.ctrl.opts.PluginInstall == nil {
		return
	}
	DrawPluginInstall(c, w.marketLanguage(), w.ctrl.opts.PluginInstall(), &w.installDialog,
		w.ctrl.opts.ConfirmPluginInstall, w.ctrl.opts.CancelPluginInstall, w.ctrl.opts.RetryPluginInstall)
}

// DrawPluginInstall presents the same review in its current native window. It never
// interprets a program declaration or grants approval: confirmation goes to the owner.
func DrawPluginInstall(c ui.C, language i18n.Language, status PluginInstallStatus, state *PluginInstallDialogState, confirm, cancel, retry func(uint64)) {
	if !status.Busy && !status.Review && !status.Failed && !status.Completed {
		return
	}
	if state.token != status.Token || state.open == nil {
		*state = PluginInstallDialogState{token: status.Token, open: new(bool)}
	}
	*state.open = true
	accepted, dismissed, retried := false, false, false
	title := i18n.Shared(language, "desktop.marketplace.reviewTitle")
	if status.Busy {
		title = i18n.Shared(language, "desktop.marketplace.installTitle")
	}
	if status.Busy && (status.Phase == "connect" || status.Phase == "download") {
		title = i18n.Shared(language, "desktop.marketplace.downloadTitle")
	}
	if status.Failed {
		title = i18n.Shared(language, "desktop.marketplace.installFailed")
	}
	if status.Completed {
		title = i18n.Shared(language, "desktop.marketplace.installComplete")
	}
	closed := ui.ModalWith(c, state.open, title, ui.ModalSpec{Width: 620, Description: status.Name + " · " + status.Version}, func() {
		if status.Failed {
			ui.Wrap(c, status.Failure)
			return
		}
		if status.Completed {
			ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.installCompleteHelp"))
			return
		}
		if status.Busy {
			ui.Row(c).FillWidth().Gap(10).Children(func() {
				ui.Spinner(c)
				label := i18n.Shared(language, "desktop.marketplace.preparing")
				if status.Phase == "connect" {
					label = i18n.Shared(language, "desktop.marketplace.connecting")
				}
				if status.Phase == "download" {
					label = i18n.Shared(language, "desktop.marketplace.downloading")
				}
				if status.Phase == "install" {
					label = i18n.Shared(language, "desktop.marketplace.installing")
				}
				ui.Text(c, label)
			})
			if status.Phase == "download" {
				received := fmt.Sprintf("%.1f", float64(status.Received)/(1<<20))
				if status.Total > 0 {
					ui.Progress(c, float32(status.Received)/float32(status.Total)).FillWidth()
					ui.Text(c, i18n.SharedFormat(language, "desktop.marketplace.downloadBytes", map[string]string{"received": received, "total": fmt.Sprintf("%.1f", float64(status.Total)/(1<<20))}))
				} else {
					ui.Text(c, i18n.SharedFormat(language, "desktop.marketplace.downloadReceived", map[string]string{"received": received}))
				}
			}
			return
		}
		if status.Reused {
			ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.reviewReused")).Muted()
		}
		ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.reviewConsent"))
		ui.Text(c, i18n.Shared(language, "desktop.marketplace.reviewPermissions")).Bold()
		if len(status.Permissions) == 0 && len(status.Programs) == 0 {
			ui.Wrap(c, i18n.Shared(language, "desktop.marketplace.reviewEmpty"))
		}
		ui.List(c.Part("permissions"), &state.permissions, len(status.Permissions), func(row ui.ListRow) {
			row.Element.FillWidth().Height(42).Children(func() {
				permission := status.Permissions[row.Index]
				ui.Column(row.C).FillWidth().Gap(3).Children(func() {
					description := permissionDescription(language, permission)
					if description != "" {
						ui.Text(row.C, description).FontSize(12).Ellipsis()
					}
					ui.Text(row.C, permission).Mono().FontSize(11).Muted().Ellipsis()
				})
			})
		}).FillWidth().Height(float32(min(210, 42*len(status.Permissions)))).Label(i18n.Shared(language, "desktop.marketplace.reviewPermissions"))
		if len(status.Programs) > 0 {
			label := i18n.SharedFormat(language, "desktop.marketplace.programDetails", map[string]string{"count": strconv.Itoa(len(status.Programs))})
			if ui.Button(c, label).Outline().Clicked() {
				state.details = !state.details
				if state.details && state.lines == nil {
					for _, raw := range status.Programs {
						var pretty bytes.Buffer
						if json.Indent(&pretty, []byte(raw), "", "  ") == nil {
							raw = pretty.String()
						}
						state.lines = append(state.lines, strings.Split(raw, "\n")...)
						state.lines = append(state.lines, "")
					}
				}
			}
			if state.details {
				ui.List(c.Part("declarations"), &state.declarations, len(state.lines), func(row ui.ListRow) {
					row.Element.FillWidth().Height(18).Hit(ui.ID(row.C), state.lines[row.Index]).Tooltip(state.lines[row.Index]).Children(func() {
						ui.Text(row.C, state.lines[row.Index]).Mono().FontSize(11).Ellipsis()
					})
				}).FillWidth().Height(180).Label(i18n.Shared(language, "desktop.marketplace.reviewPrograms"))
			}
		}
	}, func() {
		label := i18n.Shared(language, "desktop.marketplace.cancel")
		if status.Failed {
			label = i18n.Shared(language, "ui.close")
		}
		if status.Completed {
			label = i18n.Shared(language, "ui.done")
		}
		dismissed = ui.Button(c, label).Outline().Disabled(status.Busy && status.Phase == "install").Clicked()
		if status.Failed {
			retried = ui.Button(c, i18n.Shared(language, "ui.retry")).Clicked()
		}
		if status.Review {
			accepted = ui.Button(c, i18n.Shared(language, "desktop.marketplace.confirmInstall")).AutoFocus().Clicked()
		}
	})
	if retried && retry != nil {
		c.After(func() { retry(status.Token) })
	}
	if accepted && confirm != nil {
		c.After(func() { confirm(status.Token) })
	}
	if (dismissed || closed) && cancel != nil {
		c.After(func() { cancel(status.Token) })
	}
}
