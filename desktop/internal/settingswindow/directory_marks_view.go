package settingswindow

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// DirectoryMarksSnapshot is the workspace directory marks configuration shown and edited on
// the unified "Appearance & Behavior › Directory Marks & Colors" settings page.
type DirectoryMarksSnapshot struct {
	HasWorkspace        bool
	WorkspaceRoot       string
	ConfigFingerprint   string
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
	ImportIcon(ctx context.Context, base DirectoryMarksSnapshot, sourcePath string) (DirectoryMarksSnapshot, error)
	DeleteIcon(ctx context.Context, base DirectoryMarksSnapshot, id string) (DirectoryMarksSnapshot, error)
	OpenFile(path string)
}

type directoryMarksWork struct {
	source     DirectoryMarksSource
	base       DirectoryMarksSnapshot
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

func builtinDirectoryTypes(language i18n.Language) []core.CustomDirectoryType {
	return []core.CustomDirectoryType{
		{
			ID:        "builtin.sources",
			Name:      i18n.Shared(language, "desktop.directoryMarks.role.sources"),
			Tag:       "sources",
			Icon:      "sources",
			Color:     "#4e8df5",
			TintBg:    true,
			InheritBg: true,
		},
		{
			ID:        "builtin.tests",
			Name:      i18n.Shared(language, "desktop.directoryMarks.role.tests"),
			Tag:       "tests",
			Icon:      "tests",
			Color:     "#57ab5a",
			TintBg:    true,
			InheritBg: true,
		},
		{
			ID:    "builtin.resources",
			Name:  i18n.Shared(language, "desktop.directoryMarks.role.resources"),
			Tag:   "resources",
			Icon:  "resources",
			Color: "#e09b3d",
		},
		{
			ID:           "builtin.generated",
			Name:         i18n.Shared(language, "desktop.directoryMarks.role.generated"),
			Tag:          "generated",
			Icon:         "generated",
			Color:        "#9f7aea",
			TintBg:       true,
			InheritBg:    true,
			ReadOnlyHint: true,
		},
		{
			ID:              "builtin.excluded",
			Name:            i18n.Shared(language, "desktop.directoryMarks.role.excluded"),
			Tag:             "excluded",
			Icon:            "excluded",
			Color:           "#e09b3d",
			TintBg:          true,
			InheritBg:       true,
			ExcludeIndexing: true,
		},
	}
}

func settingsDirVectorIcon(name string, dark bool) gfx.Icon {
	switch name {
	case "sources", "resources", "excluded", "module", "package":
		return fileicons.ForDirectoryIconName(name, dark)
	case "tests":
		return icons.Bug
	case "generated", "gear":
		return icons.Settings
	case "star":
		return icons.Sparkles
	case "book":
		return icons.FileText
	case "archive":
		return icons.Archive
	case "database":
		return icons.Server
	default:
		return fileicons.ForDirectoryIconName("folder", dark)
	}
}

func parseDirHexColor(hexStr string, alpha float32) (gfx.Color, bool) {
	if len(hexStr) != 7 || hexStr[0] != '#' {
		return gfx.Color{}, false
	}
	v, err := strconv.ParseUint(hexStr[1:], 16, 32)
	if err != nil {
		return gfx.Color{}, false
	}
	return gfx.RGBA(uint8(v>>16), uint8((v>>8)&0xff), uint8(v&0xff), alpha), true
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
				return req.source.ImportIcon(ctx, req.base, req.importPath)
			case req.deleteIcon != "":
				return req.source.DeleteIcon(ctx, req.base, req.deleteIcon)
			case req.save != nil:
				return req.source.Save(ctx, *req.save)
			default:
				return req.source.Load(ctx)
			}
		}).Sequential()
	}
	work.source = w.ctrl.opts.DirectoryMarks
	work.base = cloneDirectoryMarksSnapshot(d.snapshot)
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
	wasImport := d.work != nil && d.work.importPath != ""
	wasIconMutation := d.work != nil && (d.work.importPath != "" || d.work.deleteIcon != "")
	if wasImport {
		d.iconImportField.SetText("")
	}
	d.snapshot = cloneDirectoryMarksSnapshot(result)
	if wasIconMutation && d.dirty {
		d.working.WorkspaceRoot = result.WorkspaceRoot
		d.working.ConfigFingerprint = result.ConfigFingerprint
		d.working.CustomIcons = append([]core.CustomDirectoryIcon(nil), result.CustomIcons...)
		if d.work.deleteIcon != "" {
			for i := range d.working.CustomTypes {
				if d.working.CustomTypes[i].Icon == d.work.deleteIcon {
					d.working.CustomTypes[i].Icon = "folder"
				}
			}
		}
	} else {
		d.working = cloneDirectoryMarksSnapshot(result)
		d.dirty = false
		d.localPathField.SetText(result.LocalConfigPath)
		d.sharedPathField.SetText(result.SharedConfigPath)
		if d.selectedID == "" {
			if len(d.working.CustomTypes) > 0 {
				d.selectedID = d.working.CustomTypes[0].ID
			} else {
				d.selectedID = "builtin.sources"
			}
		}
		d.syncTypeFields(w.marketLanguage())
	}
	d.ready = true
	d.failure = ""
}

func (d *directoryMarksDraft) findSelectedCustomType() *core.CustomDirectoryType {
	for i := range d.working.CustomTypes {
		if d.working.CustomTypes[i].ID == d.selectedID {
			return &d.working.CustomTypes[i]
		}
	}
	return nil
}

func (d *directoryMarksDraft) findSelectedType(language i18n.Language) (core.CustomDirectoryType, bool) {
	if ct := d.findSelectedCustomType(); ct != nil {
		return *ct, true
	}
	for _, bt := range builtinDirectoryTypes(language) {
		if bt.ID == d.selectedID {
			return bt, false
		}
	}
	builtins := builtinDirectoryTypes(language)
	return builtins[0], false
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

func (d *directoryMarksDraft) syncTypeFields(language i18n.Language) {
	ct, _ := d.findSelectedType(language)
	d.nameField.SetText(ct.Name)
	d.tagField.SetText(ct.Tag)
	d.colorField.SetText(ct.Color)
	d.globField.SetText(ct.MatchGlob)
}

func (d *directoryMarksDraft) pullTypeFields() {
	ct := d.findSelectedCustomType()
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

// dirFormRow renders a compact settings form row with a fixed-width label column (matching
// the prototype's 124pt label column) so address boxes and editors get full horizontal room.
func (w *window) dirFormRow(c ui.C, labelWidth float32, title, help string, body func()) {
	ui.Row(c).FillWidth().MinHeight(28).Items(ui.Start).Gap(12).Children(func() {
		ui.Row(c).Width(labelWidth).Height(28).Shrink(0).Items(ui.Center).Gap(5).Children(func() {
			ui.Text(c, title).FontSize(12).Color(w.bp.sub).Ellipsis().Shrink(1)
			if help != "" {
				w.infoButton(c, help)
			}
		})
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Children(body)
	})
}

func (w *window) dirBadge(c ui.C, text string, fg, bg gfx.Color) {
	ui.Row(c).Shrink(0).PadSides(2, 7, 2, 7).Radius(4).Background(bg).Items(ui.Center).Children(func() {
		ui.Text(c, text).FontSize(11).Color(fg).Shrink(0)
	})
}

func (w *window) directoryMarksPage(c ui.C) {
	d := &w.dirMarksDraft
	language := w.marketLanguage()
	dark := w.dark
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

		// Section 1: Configuration file address boxes & single-line display/indexing toggles.
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.sourcesTitle")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
				w.infoButton(c, i18n.Shared(language, "desktop.directoryMarks.settings.sourcesHelp"))
			})
			ui.Row(c).FillWidth().Height(1).Background(w.pal.line)

			w.dirFormRow(c, 156,
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
						w.dirBadge(c, i18n.Shared(language, "desktop.directoryMarks.settings.localStoredBadge"), w.bp.sub, w.pal.card)
					})
				},
			)

			w.dirFormRow(c, 156,
				i18n.Shared(language, "desktop.directoryMarks.settings.sharedPath"),
				i18n.Shared(language, "desktop.directoryMarks.settings.sharedPathHelp"),
				func() {
					ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
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
						if ui.Checkbox(c.Part("enable-shared"), &d.working.SharedConfigEnabled, i18n.Shared(language, "desktop.directoryMarks.settings.enabledShort")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
					})
				},
			)

			w.dirFormRow(c, 156,
				i18n.Shared(language, "desktop.directoryMarks.settings.displayBehavior"),
				i18n.Shared(language, "desktop.directoryMarks.settings.displayBehaviorHelp"),
				func() {
					ui.Flow(c).FillWidth().Gap(16).LineGap(6).Items(ui.Center).Children(func() {
						if ui.Checkbox(c.Part("show-bg"), &d.working.ShowBgTint, i18n.Shared(language, "desktop.directoryMarks.settings.showBgTint")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
						if ui.Checkbox(c.Part("show-tags"), &d.working.ShowTags, i18n.Shared(language, "desktop.directoryMarks.settings.showTags")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
						if ui.Checkbox(c.Part("git-ignore"), &d.working.GitIgnoreEnabled, i18n.Shared(language, "desktop.directoryMarks.settings.gitIgnore")).Disabled(d.busy).Changed() {
							d.dirty = true
						}
					})
				},
			)
		})

		// Section 2: Split-pane Folder Types & Color Modes (matching the design artifact).
		builtins := builtinDirectoryTypes(language)
		totalTypes := len(builtins) + len(d.working.CustomTypes)

		ui.Column(c).FillWidth().Gap(10).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.typesTitle")).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
				w.infoButton(c, i18n.Shared(language, "desktop.directoryMarks.settings.typesHelp"))
				ui.Spacer(c)
				if ui.Button(c.Part("new-type"), "+ "+i18n.Shared(language, "desktop.directoryMarks.settings.newType")).Disabled(d.busy).Clicked() {
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
					d.syncTypeFields(language)
					d.dirty = true
				}
			})

			// Split pane container.
			ui.Row(c).FillWidth().Radius(8).Stroke(1, w.pal.line).Background(w.pal.card).Clip().Children(func() {
				// Left column: grouped type list (Built-in + User Custom).
				ui.Column(c).Width(232).Shrink(0).Background(w.pal.sidebar).Children(func() {
					ui.Row(c).FillWidth().Height(34).PadX(12).Items(ui.Center).Children(func() {
						ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.typeList")).FontSize(12).Weight(gfx.WeightSemibold).Color(w.bp.sub)
						ui.Spacer(c)
						ui.Text(c, i18n.SharedFormat(language, "desktop.directoryMarks.settings.typeCount", map[string]string{"count": strconv.Itoa(totalTypes)})).FontSize(11).Color(w.bp.faint)
					})
					ui.Row(c).FillWidth().Height(1).Background(w.pal.line)

					ui.Column(c).FillWidth().Pad(8).Gap(2).Children(func() {
						ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.groupBuiltin")).FontSize(10.5).Weight(gfx.WeightSemibold).Color(w.bp.faint).PadSides(4, 6, 4, 6)
						for _, item := range builtins {
							w.dirTypeListRow(c, d, item, language, dark)
						}

						ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.groupCustom")).FontSize(10.5).Weight(gfx.WeightSemibold).Color(w.bp.faint).PadSides(10, 6, 4, 6)
						if len(d.working.CustomTypes) == 0 {
							ui.Wrap(c, i18n.Shared(language, "desktop.directoryMarks.settings.emptyTypes")).FontSize(11).Color(w.bp.faint).PadX(6)
						} else {
							for _, item := range d.working.CustomTypes {
								w.dirTypeListRow(c, d, item, language, dark)
							}
						}
					})
				})

				// Vertical divider.
				ui.Row(c).Width(1).FillHeight().Shrink(0).Background(w.pal.line)

				// Right column: selected type detail editor + live preview.
				selected, isCustom := d.findSelectedType(language)
				customPtr := d.findSelectedCustomType()
				ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Pad(16).Gap(9).Children(func() {
					// Detail header: icon + title + badge + delete button.
					iconColor := w.bp.sub
					if parsed, ok := parseDirHexColor(selected.Color, 1); ok {
						iconColor = parsed
					}
					ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
						ui.Icon(c, settingsDirVectorIcon(selected.Icon, dark)).Size(18, 18).Color(iconColor).Shrink(0)
						ui.Text(c, selected.Name).FontSize(13.5).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis().Shrink(1)
						badgeLabel := i18n.Shared(language, "desktop.directoryMarks.settings.badgeBuiltin")
						if isCustom {
							badgeLabel = i18n.Shared(language, "desktop.directoryMarks.settings.badgeCustom")
						}
						w.dirBadge(c, badgeLabel, w.bp.sub, w.pal.sidebar)
						ui.Spacer(c)
						if isCustom && customPtr != nil {
							if ui.Button(c.Part("del-type"), i18n.Shared(language, "desktop.directoryMarks.settings.deleteType")).Outline().Disabled(d.busy).Clicked() {
								next := make([]core.CustomDirectoryType, 0, len(d.working.CustomTypes)-1)
								for _, item := range d.working.CustomTypes {
									if item.ID != customPtr.ID {
										next = append(next, item)
									}
								}
								d.working.CustomTypes = next
								if len(next) > 0 {
									d.selectedID = next[0].ID
								} else {
									d.selectedID = "builtin.sources"
								}
								d.syncTypeFields(language)
								d.dirty = true
							}
						}
					})

					w.dirFormRow(c, 128, i18n.Shared(language, "desktop.directoryMarks.settings.typeName"), "", func() {
						ui.TextField(c.Part("type-name"), &d.nameField, "", "").FillWidth().Disabled(!isCustom || d.busy)
					})

					w.dirFormRow(c, 128, i18n.Shared(language, "desktop.directoryMarks.settings.typeTag"), "", func() {
						ui.TextField(c.Part("type-tag"), &d.tagField, "", "").FillWidth().Disabled(!isCustom || d.busy)
					})

					// Icon row: real vector icon buttons + expandable searchable picker for large icon sets.
					w.dirFormRow(c, 128,
						i18n.Shared(language, "desktop.directoryMarks.settings.typeIcon"),
						i18n.Shared(language, "desktop.directoryMarks.settings.importIconHelp"),
						func() {
							ui.Flow(c).FillWidth().Gap(5).LineGap(5).Items(ui.Center).Children(func() {
								for _, icName := range settingsDirIcons {
									ic := icName
									active := selected.Icon == ic
									w.dirIconTile(c.Key("tile-"+ic), ic, active, iconColor, dark, !isCustom || d.busy, func() {
										if customPtr != nil {
											customPtr.Icon = ic
											d.dirty = true
										}
									})
								}
								toggleLabel := i18n.Shared(language, "desktop.directoryMarks.settings.chooseIcon")
								if d.iconPickerOpen {
									toggleLabel = i18n.Shared(language, "desktop.directoryMarks.settings.closeIconPicker")
								}
								if ui.Button(c.Part("toggle-icon-picker"), toggleLabel).Outline().Disabled(!isCustom || d.busy).Clicked() {
									d.iconPickerOpen = !d.iconPickerOpen
								}
							})
							if isCustom && customPtr != nil && d.iconPickerOpen {
								w.directoryIconPicker(c, d, customPtr, language, dark)
							}
						},
					)

					// Color row: real circular color swatches + preview square + hex input.
					w.dirFormRow(c, 128, i18n.Shared(language, "desktop.directoryMarks.settings.typeColor"), "", func() {
						ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
							ui.Row(c).PadSides(4, 6, 4, 6).Gap(6).Radius(5).Stroke(1, w.pal.line).Background(w.pal.sidebar).Items(ui.Center).Children(func() {
								for _, sw := range settingsDirColorOptions(language) {
									hex := sw.hex
									active := strings.EqualFold(selected.Color, hex)
									swatchCol, _ := parseDirHexColor(hex, 1)
									btn := ui.ButtonBase(c.Key("sw-"+hex), sw.label).Size(18, 18).Radius(9).Background(swatchCol).Disabled(!isCustom || d.busy)
									if active {
										btn = btn.Stroke(2, w.pal.text)
									}
									if btn.Clicked() && customPtr != nil {
										customPtr.Color = hex
										d.colorField.SetText(hex)
										d.dirty = true
									}
								}
							})
							if curCol, ok := parseDirHexColor(selected.Color, 1); ok {
								ui.Row(c).Size(24, 22).Radius(4).Background(curCol).Stroke(1, w.pal.line).Shrink(0)
							}
							ui.TextField(c.Part("type-color"), &d.colorField, "#4e8df5", "").Width(96).Disabled(!isCustom || d.busy)
						})
					})

					// Visual & Semantic behavior checkboxes.
					w.dirFormRow(c, 128, i18n.Shared(language, "desktop.directoryMarks.settings.visualSemantics"), "", func() {
						tintBg := selected.TintBg
						tintText := selected.TintText
						inheritBg := selected.InheritBg
						excl := selected.ExcludeIndexing
						ro := selected.ReadOnlyHint
						disabled := !isCustom || d.busy
						if ui.Checkbox(c.Part("ct-tint-bg"), &tintBg, i18n.Shared(language, "desktop.directoryMarks.settings.tintBg")).Disabled(disabled).Changed() && customPtr != nil {
							customPtr.TintBg = tintBg
							d.dirty = true
						}
						if ui.Checkbox(c.Part("ct-tint-text"), &tintText, i18n.Shared(language, "desktop.directoryMarks.settings.tintText")).Disabled(disabled).Changed() && customPtr != nil {
							customPtr.TintText = tintText
							d.dirty = true
						}
						if ui.Checkbox(c.Part("ct-inherit-bg"), &inheritBg, i18n.Shared(language, "desktop.directoryMarks.settings.inheritBg")).Disabled(disabled).Changed() && customPtr != nil {
							customPtr.InheritBg = inheritBg
							d.dirty = true
						}
						if ui.Checkbox(c.Part("ct-excl"), &excl, i18n.Shared(language, "desktop.directoryMarks.settings.excludeIndexing")).Disabled(disabled).Changed() && customPtr != nil {
							customPtr.ExcludeIndexing = excl
							d.dirty = true
						}
						if ui.Checkbox(c.Part("ct-ro"), &ro, i18n.Shared(language, "desktop.directoryMarks.settings.readOnlyHint")).Disabled(disabled).Changed() && customPtr != nil {
							customPtr.ReadOnlyHint = ro
							d.dirty = true
						}
					})

					w.dirFormRow(c, 128,
						i18n.Shared(language, "desktop.directoryMarks.settings.typeGlob"),
						i18n.Shared(language, "desktop.directoryMarks.settings.typeGlobHelp"),
						func() {
							ui.TextField(c.Part("type-glob"), &d.globField, "**/fixtures, legacy/**", "").FillWidth().Disabled(!isCustom || d.busy)
						},
					)

					if isCustom {
						d.pullTypeFields()
						selected, _ = d.findSelectedType(language)
					}

					// Live tree row preview card (2 rows: folder + child file).
					ui.Column(c).FillWidth().Gap(5).PadTop(4).Children(func() {
						ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.livePreview")).FontSize(11.5).Color(w.bp.faint)
						w.dirLivePreview(c, selected, dark)
					})
				})
			})

			// Draft footer bar.
			if d.failure != "" {
				ui.Wrap(c, d.failure).Color(w.pal.danger)
			}
			ui.Row(c).FillWidth().Items(ui.Center).Gap(8).PadTop(4).Children(func() {
				if d.dirty {
					dot(c, 7, w.pal.accent)
					ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.unsavedDraft")).FontSize(12).Color(w.pal.text)
				}
				ui.Spacer(c)
				if ui.Button(c.Part("dir-refresh"), i18n.Shared(language, "ui.refresh")).Outline().Disabled(d.busy).Clicked() {
					w.startDirectoryMarks(&directoryMarksWork{})
				}
				if ui.Button(c.Part("dir-discard"), i18n.Shared(language, "desktop.directoryMarks.settings.discard")).Outline().Disabled(!d.ready || d.busy || !d.dirty).Clicked() {
					d.working = cloneDirectoryMarksSnapshot(d.snapshot)
					d.dirty = false
					d.localPathField.SetText(d.working.LocalConfigPath)
					d.sharedPathField.SetText(d.working.SharedConfigPath)
					d.syncTypeFields(language)
				}
				if ui.Button(c.Part("dir-apply"), i18n.Shared(language, "desktop.buildSettings.apply")).Disabled(!d.ready || d.busy || !d.dirty).Clicked() {
					d.pullTypeFields()
					next := cloneDirectoryMarksSnapshot(d.working)
					w.startDirectoryMarks(&directoryMarksWork{save: &next})
				}
			})
		})
	})
}

func (w *window) dirTypeListRow(c ui.C, d *directoryMarksDraft, item core.CustomDirectoryType, language i18n.Language, dark bool) {
	selected := d.selectedID == item.ID
	iconColor := w.bp.sub
	tagFg := w.bp.sub
	tagBg := w.pal.card
	if col, ok := parseDirHexColor(item.Color, 1); ok {
		iconColor = col
		tagFg = col
	}
	if bg, ok := parseDirHexColor(item.Color, 0.14); ok {
		tagBg = bg
	}
	label := item.Name
	if strings.TrimSpace(label) == "" {
		label = item.ID
	}
	btn := ui.ButtonBase(c.Key("type-row-"+item.ID), label).FillWidth().Height(28).PadX(8).Radius(5).Items(ui.Center).Gap(7)
	if selected {
		btn = btn.Background(gfx.RGBA(53, 116, 240, 0.16))
	}
	if btn.Clicked() {
		d.pullTypeFields()
		d.selectedID = item.ID
		d.syncTypeFields(language)
	}
	btn.Children(func() {
		ui.Icon(c, settingsDirVectorIcon(item.Icon, dark)).Size(14, 14).Color(iconColor).Shrink(0)
		ui.Text(c, label).FontSize(12).Color(w.pal.text).Ellipsis().Grow(1).Shrink(1).MinWidth(0)
		if item.Tag != "" {
			ui.Row(c).Shrink(0).PadSides(1, 5, 1, 5).Radius(3).Background(tagBg).Children(func() {
				ui.Text(c, item.Tag).FontSize(10.5).Color(tagFg).Shrink(0)
			})
		}
	})
}

func (w *window) dirIconTile(c ui.C, iconName string, active bool, activeColor gfx.Color, dark, disabled bool, onClick func()) {
	btn := ui.ButtonBase(c, iconName).Size(28, 28).Radius(5).Center().Disabled(disabled)
	if active {
		btn = btn.Background(gfx.RGBA(53, 116, 240, 0.16)).Stroke(1, w.pal.accent)
	} else {
		btn = btn.Background(w.pal.sidebar).Stroke(1, w.pal.line)
	}
	if btn.Clicked() {
		onClick()
	}
	tint := w.bp.sub
	if active {
		tint = activeColor
	}
	btn.Children(func() {
		ui.Icon(c, settingsDirVectorIcon(iconName, dark)).Size(15, 15).Color(tint)
	})
}

func (w *window) dirLivePreview(c ui.C, ct core.CustomDirectoryType, dark bool) {
	alpha := float32(0.11)
	if dark {
		alpha = 0.14
	}
	accent, hasColor := parseDirHexColor(ct.Color, 1)
	bgTint, hasBg := parseDirHexColor(ct.Color, alpha)
	tagBg, _ := parseDirHexColor(ct.Color, 0.16)

	ui.Column(c).FillWidth().Radius(6).Stroke(1, w.pal.line).Background(w.pal.sidebar).Clip().Children(func() {
		// Row 1: folder row.
		r1 := ui.Row(c).FillWidth().Height(26).PadSides(0, 10, 0, 10).Items(ui.Center).Gap(6)
		if ct.TintBg && hasBg {
			r1 = r1.Background(bgTint)
		}
		r1.Children(func() {
			if ct.TintBg && hasColor {
				ui.Row(c).Width(2).FillHeight().Background(accent).Shrink(0)
			}
			ui.Icon(c, icons.ChevronDown).Size(12, 12).Color(w.bp.faint).Shrink(0)
			icTint := w.bp.sub
			if hasColor {
				icTint = accent
			}
			ui.Icon(c, settingsDirVectorIcon(ct.Icon, dark)).Size(14, 14).Color(icTint).Shrink(0)
			nameCol := w.pal.text
			if ct.ExcludeIndexing {
				nameCol = w.bp.faint
			} else if ct.TintText && hasColor {
				nameCol = accent
			}
			ui.Text(c, "example-folder").FontSize(12.5).Color(nameCol).Shrink(0)
			if ct.Tag != "" {
				fg := w.bp.sub
				if hasColor {
					fg = accent
				}
				ui.Row(c).Shrink(0).PadSides(1, 5, 1, 5).Radius(3).Background(tagBg).Children(func() {
					ui.Text(c, ct.Tag).FontSize(10.5).Color(fg).Shrink(0)
				})
			}
		})

		// Row 2: child file row (shows background inheritance).
		r2 := ui.Row(c).FillWidth().Height(26).PadSides(0, 10, 0, 32).Items(ui.Center).Gap(6)
		if ct.TintBg && ct.InheritBg && hasBg {
			r2 = r2.Background(bgTint)
		}
		r2.Children(func() {
			ui.Icon(c, icons.FileText).Size(14, 14).Color(w.bp.sub).Shrink(0)
			fileCol := w.pal.text
			if ct.ExcludeIndexing {
				fileCol = w.bp.faint
			}
			ui.Text(c, "SampleFile.java").FontSize(12.5).Color(fileCol).Shrink(0)
		})
	})
}

// directoryIconPicker renders a bounded, searchable, categorized icon selector with custom
// SVG import and deletion so large icon libraries never blow up the form height.
func (w *window) directoryIconPicker(c ui.C, d *directoryMarksDraft, ct *core.CustomDirectoryType, language i18n.Language, dark bool) {
	accent, hasColor := parseDirHexColor(ct.Color, 1)
	if !hasColor {
		accent = w.pal.accent
	}
	ui.Column(c).FillWidth().Pad(10).Gap(8).Radius(6).Stroke(1, w.pal.line).Background(w.pal.sidebar).Children(func() {
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

		query := strings.ToLower(strings.TrimSpace(d.iconSearchField.Text()))
		type iconOption struct {
			id    string
			label string
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
					options = append(options, iconOption{id: ci.ID, label: ci.Name})
				}
			}
		}

		ui.Scroll(c.Part("icon-grid")).FillWidth().MaxHeight(136).Scrollbars().Children(func() {
			if len(options) == 0 {
				ui.Text(c, i18n.Shared(language, "desktop.directoryMarks.settings.noMatchingIcons")).FontSize(12).Muted()
				return
			}
			ui.Flow(c).FillWidth().Gap(6).LineGap(6).Children(func() {
				for _, opt := range options {
					id := opt.id
					active := ct.Icon == id
					btn := ui.ButtonBase(c.Key("pick-"+id), opt.label).Height(26).PadX(8).Radius(4).Items(ui.Center).Gap(5).Disabled(d.busy)
					if active {
						btn = btn.Background(gfx.RGBA(53, 116, 240, 0.16)).Stroke(1, w.pal.accent)
					} else {
						btn = btn.Background(w.pal.card).Stroke(1, w.pal.line)
					}
					if btn.Clicked() {
						ct.Icon = id
						d.dirty = true
					}
					btn.Children(func() {
						icTint := w.bp.sub
						if active {
							icTint = accent
						}
						ui.Icon(c, settingsDirVectorIcon(id, dark)).Size(13, 13).Color(icTint).Shrink(0)
						ui.Text(c, opt.label).FontSize(11.5).Color(w.pal.text).Shrink(0)
					})
				}
			})
		})

		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			ui.TextField(c.Part("icon-import-path"), &d.iconImportField, i18n.Shared(language, "desktop.directoryMarks.settings.importIconPath"), "").Grow(1).Disabled(d.busy)
			if ui.Button(c.Part("icon-import-btn"), i18n.Shared(language, "desktop.directoryMarks.settings.importIcon")).Outline().Disabled(d.busy).Clicked() {
				if p := strings.TrimSpace(d.iconImportField.Text()); p != "" {
					w.startDirectoryMarks(&directoryMarksWork{importPath: p})
				} else {
					c.After(w.pickDirectoryIconSVG)
				}
			}
			if d.isCustomIcon(ct.Icon) {
				delID := ct.Icon
				if ui.Button(c.Part("del-custom-icon"), i18n.Shared(language, "desktop.directoryMarks.settings.deleteIcon")).Outline().Disabled(d.busy).Clicked() {
					w.startDirectoryMarks(&directoryMarksWork{deleteIcon: delID})
				}
			}
		})
	})
}

// pickDirectoryIconSVG opens the native file dialog filtered to .svg files and imports the chosen icon.
func (w *window) pickDirectoryIconSVG() {
	paths, err := app.OpenFiles(app.OpenFileOptions{
		Title:   i18n.Shared(w.marketLanguage(), "desktop.directoryMarks.settings.importIcon"),
		Filters: []app.FileFilter{{Name: "SVG", Pattern: "*.svg"}},
	})
	// log-exempt: user canceled native SVG file picker
	if errors.Is(err, app.ErrCanceled) || len(paths) == 0 {
		return
	}
	if err != nil {
		w.dirMarksDraft.failure = i18n.Shared(w.marketLanguage(), "desktop.directoryMarks.settings.failed")
		w.reportEssentialsFailure("directory_icon_pick", err)
		w.inv.Invalidate()
		return
	}
	w.dirMarksDraft.iconImportField.SetText(paths[0])
	w.startDirectoryMarks(&directoryMarksWork{importPath: paths[0]})
}
