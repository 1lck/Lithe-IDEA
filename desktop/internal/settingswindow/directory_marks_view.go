package settingswindow

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// DirectoryMarksSnapshot is the workspace directory marks configuration shown and edited on
// the unified "Appearance & Behavior › Directory Marks & Colors" settings page.
type DirectoryMarksSnapshot struct {
	HasWorkspace        bool
	LocalConfigPath     string
	SharedConfigEnabled bool
	SharedConfigPath    string
	ShowBgTint          bool
	ShowTags            bool
	GitIgnoreEnabled    bool
	CustomTypes         []core.CustomDirectoryType
	CustomIcons         []core.CustomDirectoryIcon
}

// DirectoryMarksSource loads, saves, imports/deletes custom SVG icons and opens config files.
type DirectoryMarksSource interface {
	Load(ctx context.Context) (DirectoryMarksSnapshot, error)
	Save(ctx context.Context, next DirectoryMarksSnapshot) (DirectoryMarksSnapshot, error)
	ImportIcon(ctx context.Context, sourcePath string) (DirectoryMarksSnapshot, error)
	DeleteIcon(ctx context.Context, id string) (DirectoryMarksSnapshot, error)
	OpenFile(path string)
}

type directoryMarksWork struct {
	source     DirectoryMarksSource
	save       *DirectoryMarksSnapshot
	importPath string
	deleteIcon string
}

type iconFilterKind uint8

const (
	iconFilterAll iconFilterKind = iota
	iconFilterBuiltin
	iconFilterCustom
)

type directoryMarksDraft struct {
	ready, busy, dirty bool
	failure            string
	snapshot           DirectoryMarksSnapshot
	working            DirectoryMarksSnapshot
	selectedID         string

	iconPickerOpen bool
	iconFilter     iconFilterKind

	localPathField  ui.Field
	sharedPathField ui.Field
	nameField       ui.Field
	tagField        ui.Field
	colorField      ui.Field
	globField       ui.Field
	iconSearchField ui.Field
	iconImportField ui.Field

	work   *directoryMarksWork
	effect *ui.EffectState[DirectoryMarksSnapshot, *directoryMarksWork]
}

var settingsDirIcons = []string{
	"folder", "sources", "tests", "resources", "generated", "excluded",
	"star", "book", "archive", "database", "gear",
}

var settingsDirColorHexes = []string{
	"#4e8df5", "#57ab5a", "#e09b3d", "#9f7aea", "#38b2ac", "#e56b6f", "#8b949e",
}

func settingsDirColorOptions(language i18n.Language) []struct {
	label string
	hex   string
} {
	return []struct {
		label string
		hex   string
	}{
		{i18n.Shared(language, "desktop.directoryMarks.color.blue"), "#4e8df5"},
		{i18n.Shared(language, "desktop.directoryMarks.color.green"), "#57ab5a"},
		{i18n.Shared(language, "desktop.directoryMarks.color.amber"), "#e09b3d"},
		{i18n.Shared(language, "desktop.directoryMarks.color.purple"), "#9f7aea"},
		{i18n.Shared(language, "desktop.directoryMarks.color.teal"), "#38b2ac"},
		{i18n.Shared(language, "desktop.directoryMarks.color.rose"), "#e56b6f"},
		{i18n.Shared(language, "desktop.directoryMarks.color.slate"), "#8b949e"},
	}
}

func cloneDirectoryMarksSnapshot(src DirectoryMarksSnapshot) DirectoryMarksSnapshot {
	out := src
	if len(src.CustomTypes) > 0 {
		out.CustomTypes = append([]core.CustomDirectoryType(nil), src.CustomTypes...)
	}
	if len(src.CustomIcons) > 0 {
		out.CustomIcons = append([]core.CustomDirectoryIcon(nil), src.CustomIcons...)
	}
	return out
}

func (w *window) startDirectoryMarks(work *directoryMarksWork) {
	d := &w.dirMarksDraft
	if d.busy || w.sess.finished.Load() {
		return
	}
	if d.effect == nil {
		d.effect = ui.NewEffectKeyed[DirectoryMarksSnapshot, *directoryMarksWork](func(ctx context.Context, req *directoryMarksWork) (DirectoryMarksSnapshot, error) {
			ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			if req.source == nil {
				return DirectoryMarksSnapshot{}, errors.New("directory marks source unavailable")
			}
			switch {
			case req.importPath != "":
				return req.source.ImportIcon(ctx, req.importPath)
			case req.deleteIcon != "":
				return req.source.DeleteIcon(ctx, req.deleteIcon)
			case req.save != nil:
				return req.source.Save(ctx, *req.save)
			default:
				return req.source.Load(ctx)
			}
		}).Sequential()
	}
	work.source = w.ctrl.opts.DirectoryMarks
	d.work = work
	d.busy = true
	d.failure = ""
	w.inv.Invalidate()
}

func (w *window) takeDirectoryMarks() {
	d := &w.dirMarksDraft
	if d.effect == nil {
		return
	}
	result, err, ok := d.effect.Take()
	if !ok {
		return
	}
	d.busy = false
	if err != nil {
		d.failure = i18n.Shared(w.marketLanguage(), "desktop.directoryMarks.settings.failed")
		w.reportEssentialsFailure("directory_marks", err)
		return
	}
	wasIconMutation := d.work != nil && (d.work.importPath != "" || d.work.deleteIcon != "")
	d.snapshot = cloneDirectoryMarksSnapshot(result)
	if wasIconMutation && d.dirty {
		// Preserve in-progress custom type edits while updating the icon library.
		d.working.CustomIcons = append([]core.CustomDirectoryIcon(nil), result.CustomIcons...)
		if d.work.deleteIcon != "" {
			for i := range d.working.CustomTypes {
				if d.working.CustomTypes[i].Icon == d.work.deleteIcon {
					d.working.CustomTypes[i].Icon = "folder"
				}
			}
		}
		if d.work.importPath != "" {
			d.iconImportField.SetText("")
		}
	} else {
		d.working = cloneDirectoryMarksSnapshot(result)
		d.dirty = false
		d.localPathField.SetText(result.LocalConfigPath)
		d.sharedPathField.SetText(result.SharedConfigPath)
		if len(d.working.CustomTypes) > 0 {
			if d.findSelectedType() == nil {
				d.selectedID = d.working.CustomTypes[0].ID
			}
			d.syncTypeFields()
		} else {
			d.selectedID = ""
		}
	}
	d.ready = true
	d.failure = ""
}

func (d *directoryMarksDraft) findSelectedType() *core.CustomDirectoryType {
	for i := range d.working.CustomTypes {
		if d.working.CustomTypes[i].ID == d.selectedID {
			return &d.working.CustomTypes[i]
		}
	}
	return nil
}

func (d *directoryMarksDraft) iconDisplayName(id string) string {
	for _, ci := range d.working.CustomIcons {
		if ci.ID == id {
			return ci.Name
		}
	}
	return id
}

func (d *directoryMarksDraft) isCustomIcon(id string) bool {
	for _, ci := range d.working.CustomIcons {
		if ci.ID == id {
			return true
		}
	}
	return false
}

func (d *directoryMarksDraft) syncTypeFields() {
	ct := d.findSelectedType()
	if ct == nil {
		return
	}
	d.nameField.SetText(ct.Name)
	d.tagField.SetText(ct.Tag)
	d.colorField.SetText(ct.Color)
	d.globField.SetText(ct.MatchGlob)
}

func (d *directoryMarksDraft) pullTypeFields() {
	ct := d.findSelectedType()
	if ct == nil {
		return
	}
	if v := d.nameField.Text(); v != ct.Name {
		ct.Name = v
		d.dirty = true
	}
	if v := d.tagField.Text(); v != ct.Tag {
		ct.Tag = v
		d.dirty = true
	}
	if v := d.colorField.Text(); v != ct.Color {
		ct.Color = v
		d.dirty = true
	}
	if v := d.globField.Text(); v != ct.MatchGlob {
		ct.MatchGlob = v
		d.dirty = true
	}
}

// directoryMultiRow keeps the same 40%/60% two-column alignment as settingsRow while letting
// multi-line controls (stacked checkboxes, color swatches, icon picker) grow vertically.
func (w *window) directoryMultiRow(c ui.C, title, help string, body func()) {
	ui.Row(c).FillWidth().MinHeight(28).Items(ui.Start).Gap(12).Children(func() {
		ui.Row(c).WidthPercent(40).Height(28).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).Children(func() {
			ui.Text(c, title).FontSize(12).Color(w.pal.text).Ellipsis().Shrink(1)
			if help != "" {
				w.infoButton(c, help)
			}
		})
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Children(body)
	})
}

func (w *window) directoryMarksPage(c ui.C) {
	d := &w.dirMarksDraft
	language := w.marketLanguage()
	if d.work == nil {
		w.startDirectoryMarks(&directoryMarksWork{})
	}
	w.pageScroll(c, pageDirectoryMarks, func() {
		if !d.ready && d.busy {
			ui.Text(c, i18n.Shared(language, "quickOpen.searching")).Muted()
			return
		}
		if d.ready && !d.working.HasWorkspace {
			w.card(c, i18n.Shared(language, "desktop.directoryMarks.pageTitle"), "", func() {
				ui.Wrap(c, i18n.Shared(language, "desktop.directoryMarks.settings.noWorkspace")).Muted()
			})
			return
		}

		// Card 1: Configuration file addresses & general display/indexing toggles.
		w.card(c,
			i18n.Shared(language, "desktop.directoryMarks.settings.sourcesTitle"),
			i18n.Shared(language, "desktop.directoryMarks.settings.sourcesHelp"),
			func() {
				w.settingsRow(c,
					i18n.Shared(language, "desktop.directoryMarks.settings.localPath"),
					i18n.Shared(language, "desktop.directoryMarks.settings.localPathHelp"),
					func() {
						ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
							ui.TextField(c.Part("local-path"), &d.localPathField, "", "").Grow(1).ReadOnly(true)
							if ui.Button(c.Part("open-local"), i18n.Shared(language, "desktop.directoryMarks.settings.openFile")).Outline().Disabled(d.working.LocalConfigPath == "").Clicked() {
								if w.ctrl.opts.DirectoryMarks != nil {
									w.ctrl.opts.DirectoryMarks.OpenFile(d.working.LocalConfigPath)
								}
							}
						})
					},
				)

				w.directoryMultiRow(c,
					i18n.Shared(language, "desktop.directoryMarks.settings.sharedPath"),
					i18n.Shared(language, "desktop.directoryMarks.settings.sharedPathHelp"),
					func() {
						ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
							ui.TextField(c.Part("shared-path"), &d.sharedPathField, ".lithe/directories.json", "").Grow(1).Disabled(!d.working.SharedConfigEnabled || d.busy)
							if v := d.sharedPathField.Text(); v != d.working.SharedConfigPath {
								d.working.SharedConfigPath = v
								d.dirty = true
							}
							if ui.Button(c.Part("open-shared"), i18n.Shared(language, "desktop.directoryMarks.settings.openFile")).Outline().Disabled(!d.working.SharedConfigEnabled || strings.TrimSpace(d.working.SharedConfigPath) == "").Clicked() {
								if w.ctrl.opts.DirectoryMarks != nil {
									w.ctrl.opts.DirectoryMarks.OpenFile(strings.TrimSpace(d.working.SharedConfigPath))
								}
							}
						})
						if ui.Checkbox(c.Part("enable-shared"), &d.working.SharedConfigEnabled, i18n.Shared(language, "desktop.directoryMarks.settings.enableShared")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
					},
				)

				w.directoryMultiRow(c,
					i18n.Shared(language, "desktop.directoryMarks.settings.displayBehavior"),
					i18n.Shared(language, "desktop.directoryMarks.settings.displayBehaviorHelp"),
					func() {
						if ui.Checkbox(c.Part("show-bg"), &d.working.ShowBgTint, i18n.Shared(language, "desktop.directoryMarks.settings.showBgTint")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
						if ui.Checkbox(c.Part("show-tags"), &d.working.ShowTags, i18n.Shared(language, "desktop.directoryMarks.settings.showTags")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
						if ui.Checkbox(c.Part("git-ignore"), &d.working.GitIgnoreEnabled, i18n.Shared(language, "desktop.directoryMarks.settings.gitIgnore")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
					},
				)
			},
		)

		// Card 2: Custom folder types & color modes.
		w.card(c,
			i18n.Shared(language, "desktop.directoryMarks.settings.typesTitle"),
			i18n.Shared(language, "desktop.directoryMarks.settings.typesHelp"),
			func() {
				ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
					if ui.Button(c.Part("new-type"), i18n.Shared(language, "desktop.directoryMarks.settings.newType")).Disabled(d.busy).Clicked() {
						d.pullTypeFields()
						idx := len(d.working.CustomTypes) + 1
						newID := fmt.Sprintf("custom.mode_%d", time.Now().UnixMilli()%100000)
						ct := core.CustomDirectoryType{
							ID:        newID,
							Name:      fmt.Sprintf("Custom %d", idx),
							Tag:       fmt.Sprintf("custom-%d", idx),
							Icon:      "star",
							Color:     settingsDirColorHexes[(idx-1)%len(settingsDirColorHexes)],
							TintBg:    true,
							InheritBg: true,
						}
						d.working.CustomTypes = append(d.working.CustomTypes, ct)
						d.selectedID = ct.ID
						d.syncTypeFields()
						d.dirty = true
					}
					if ct := d.findSelectedType(); ct != nil {
						if ui.Button(c.Part("del-type"), i18n.Shared(language, "desktop.directoryMarks.settings.deleteType")).Outline().Disabled(d.busy).Clicked() {
							next := make([]core.CustomDirectoryType, 0, len(d.working.CustomTypes)-1)
							for _, item := range d.working.CustomTypes {
								if item.ID != ct.ID {
									next = append(next, item)
								}
							}
							d.working.CustomTypes = next
							if len(next) > 0 {
								d.selectedID = next[0].ID
								d.syncTypeFields()
							} else {
								d.selectedID = ""
							}
							d.dirty = true
						}
					}
				})

				if len(d.working.CustomTypes) == 0 {
					ui.Wrap(c, i18n.Shared(language, "desktop.directoryMarks.settings.emptyTypes")).Muted()
				} else {
					ui.Flow(c).FillWidth().Gap(6).LineGap(6).Children(func() {
						for _, item := range d.working.CustomTypes {
							id := item.ID
							label := item.Name
							if strings.TrimSpace(label) == "" {
								label = id
							}
							btn := ui.Button(c.Key(id), label)
							if id != d.selectedID {
								btn = btn.Outline()
							}
							if btn.Clicked() {
								d.pullTypeFields()
								d.selectedID = id
								d.syncTypeFields()
							}
						}
					})

					if ct := d.findSelectedType(); ct != nil {
						w.settingsRow(c, i18n.Shared(language, "desktop.directoryMarks.settings.typeName"), "", func() {
							ui.TextField(c.Part("type-name"), &d.nameField, "", "").Width(260).Disabled(d.busy)
						})
						w.settingsRow(c, i18n.Shared(language, "desktop.directoryMarks.settings.typeTag"), "", func() {
							ui.TextField(c.Part("type-tag"), &d.tagField, "", "").Width(180).Disabled(d.busy)
						})

						// Scalable searchable icon picker with add/delete custom SVG icons.
						w.directoryMultiRow(c,
							i18n.Shared(language, "desktop.directoryMarks.settings.typeIcon"),
							i18n.Shared(language, "desktop.directoryMarks.settings.importIconHelp"),
							func() {
								ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
									ui.Text(c, d.iconDisplayName(ct.Icon)).FontSize(12).Weight(gfx.WeightMedium)
									toggleLabel := i18n.Shared(language, "desktop.directoryMarks.settings.chooseIcon")
									if d.iconPickerOpen {
										toggleLabel = i18n.Shared(language, "desktop.directoryMarks.settings.closeIconPicker")
									}
									if ui.Button(c.Part("toggle-icon-picker"), toggleLabel).Outline().Disabled(d.busy).Clicked() {
										d.iconPickerOpen = !d.iconPickerOpen
									}
									if d.isCustomIcon(ct.Icon) {
										delID := ct.Icon
										if ui.Button(c.Part("del-custom-icon"), i18n.Shared(language, "desktop.directoryMarks.settings.deleteIcon")).Outline().Disabled(d.busy).Clicked() {
											w.startDirectoryMarks(&directoryMarksWork{deleteIcon: delID})
										}
									}
								})
								if d.iconPickerOpen {
									w.directoryIconPicker(c, d, ct, language)
								}
							},
						)

						w.directoryMultiRow(c, i18n.Shared(language, "desktop.directoryMarks.settings.typeColor"), "", func() {
							ui.Flow(c).FillWidth().Gap(4).LineGap(4).Children(func() {
								for _, sw := range settingsDirColorOptions(language) {
									hex := sw.hex
									b := ui.Button(c.Key("col-"+hex), sw.label)
									if !strings.EqualFold(ct.Color, hex) {
										b = b.Outline()
									}
									if b.Disabled(d.busy).Clicked() {
										ct.Color = hex
										d.colorField.SetText(hex)
										d.dirty = true
									}
								}
							})
							ui.TextField(c.Part("type-color"), &d.colorField, "#4e8df5", "").Width(120).Disabled(d.busy)
						})
						w.settingsRow(c, i18n.Shared(language, "desktop.directoryMarks.settings.typeGlob"), i18n.Shared(language, "desktop.directoryMarks.settings.typeGlobHelp"), func() {
							ui.TextField(c.Part("type-glob"), &d.globField, "**/fixtures, legacy/**", "").Width(300).Disabled(d.busy)
						})
						w.directoryMultiRow(c, i18n.Shared(language, "desktop.directoryMarks.settings.displayBehavior"), "", func() {
							if ui.Checkbox(c.Part("ct-tint-bg"), &ct.TintBg, i18n.Shared(language, "desktop.directoryMarks.settings.tintBg")).Disabled(d.busy).Changed() {
								d.dirty = true
							}
							if ui.Checkbox(c.Part("ct-tint-text"), &ct.TintText, i18n.Shared(language, "desktop.directoryMarks.settings.tintText")).Disabled(d.busy).Changed() {
								d.dirty = true
							}
							if ui.Checkbox(c.Part("ct-inherit-bg"), &ct.InheritBg, i18n.Shared(language, "desktop.directoryMarks.settings.inheritBg")).Disabled(d.busy).Changed() {
								d.dirty = true
							}
							if ui.Checkbox(c.Part("ct-excl"), &ct.ExcludeIndexing, i18n.Shared(language, "desktop.directoryMarks.settings.excludeIndexing")).Disabled(d.busy).Changed() {
								d.dirty = true
							}
							if ui.Checkbox(c.Part("ct-ro"), &ct.ReadOnlyHint, i18n.Shared(language, "desktop.directoryMarks.settings.readOnlyHint")).Disabled(d.busy).Changed() {
								d.dirty = true
							}
						})
						d.pullTypeFields()
					}
				}

				if d.failure != "" {
					ui.Wrap(c, d.failure).Color(w.pal.danger)
				}
				if d.dirty {
					ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.unsavedDraft")).FontSize(12).Color(w.pal.accent).Weight(gfx.WeightMedium)
				}
				ui.Row(c).Gap(8).Children(func() {
					if ui.Button(c.Part("dir-apply"), i18n.Shared(language, "desktop.buildSettings.apply")).Disabled(!d.ready || d.busy || !d.dirty).Clicked() {
						d.pullTypeFields()
						next := cloneDirectoryMarksSnapshot(d.working)
						w.startDirectoryMarks(&directoryMarksWork{save: &next})
					}
					if ui.Button(c.Part("dir-discard"), i18n.Shared(language, "desktop.directoryMarks.settings.discard")).Outline().Disabled(!d.ready || d.busy || !d.dirty).Clicked() {
						d.working = cloneDirectoryMarksSnapshot(d.snapshot)
						d.dirty = false
						d.localPathField.SetText(d.working.LocalConfigPath)
						d.sharedPathField.SetText(d.working.SharedConfigPath)
						d.syncTypeFields()
					}
					if ui.Button(c.Part("dir-refresh"), i18n.Shared(language, "ui.refresh")).Outline().Disabled(d.busy).Clicked() {
						w.startDirectoryMarks(&directoryMarksWork{})
					}
				})
			},
		)
	})
}

// directoryIconPicker renders a bounded, searchable, categorized icon selector with custom
// SVG import and deletion so large icon libraries never blow up the form height.
func (w *window) directoryIconPicker(c ui.C, d *directoryMarksDraft, ct *core.CustomDirectoryType, language i18n.Language) {
	ui.Column(c).FillWidth().Pad(10).Gap(8).Radius(6).Stroke(1, w.pal.line).Background(w.pal.sidebar).Children(func() {
		// Search + category filter bar.
		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			ui.TextField(c.Part("icon-search"), &d.iconSearchField, i18n.Shared(language, "desktop.directoryMarks.settings.searchIcons"), "").Grow(1)
			filters := []struct {
				kind  iconFilterKind
				label string
			}{
				{iconFilterAll, i18n.Shared(language, "desktop.directoryMarks.settings.iconFilterAll")},
				{iconFilterBuiltin, i18n.Shared(language, "desktop.directoryMarks.settings.iconFilterBuiltin")},
				{iconFilterCustom, i18n.Shared(language, "desktop.directoryMarks.settings.iconFilterCustom")},
			}
			for _, f := range filters {
				fk := f.kind
				b := ui.Button(c.KeyInt(int(fk)), f.label)
				if d.iconFilter != fk {
					b = b.Outline()
				}
				if b.Clicked() {
					d.iconFilter = fk
				}
			}
		})

		// Bounded scrollable grid of matching icons.
		query := strings.ToLower(strings.TrimSpace(d.iconSearchField.Text()))
		type iconOption struct {
			id     string
			label  string
			custom bool
		}
		var options []iconOption
		if d.iconFilter != iconFilterCustom {
			for _, name := range settingsDirIcons {
				if query == "" || strings.Contains(strings.ToLower(name), query) {
					options = append(options, iconOption{id: name, label: name})
				}
			}
		}
		if d.iconFilter != iconFilterBuiltin {
			for _, ci := range d.working.CustomIcons {
				if query == "" || strings.Contains(strings.ToLower(ci.Name), query) || strings.Contains(strings.ToLower(ci.ID), query) {
					options = append(options, iconOption{id: ci.ID, label: ci.Name, custom: true})
				}
			}
		}

		ui.Scroll(c.Part("icon-grid")).FillWidth().MaxHeight(150).Scrollbars().Children(func() {
			if len(options) == 0 {
				ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.noMatchingIcons")).FontSize(12).Muted()
				return
			}
			ui.Flow(c).FillWidth().Gap(6).LineGap(6).Children(func() {
				for _, opt := range options {
					id := opt.id
					b := ui.Button(c.Key("pick-"+id), opt.label)
					if ct.Icon != id {
						b = b.Outline()
					}
					if b.Disabled(d.busy).Clicked() {
						ct.Icon = id
						d.dirty = true
					}
				}
			})
		})

		// Import custom SVG icon row (stored in user config dir, never in app bundle).
		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			ui.TextField(c.Part("icon-import-path"), &d.iconImportField, i18n.Shared(language, "desktop.directoryMarks.settings.importIconPath"), "").Grow(1).Disabled(d.busy)
			if ui.Button(c.Part("icon-import-btn"), i18n.Shared(language, "desktop.directoryMarks.settings.importIcon")).Outline().Disabled(d.busy || strings.TrimSpace(d.iconImportField.Text()) == "").Clicked() {
				w.startDirectoryMarks(&directoryMarksWork{importPath: strings.TrimSpace(d.iconImportField.Text())})
			}
		})
	})
}
