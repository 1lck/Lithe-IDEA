package settingswindow

import (
	"errors"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/keymapimport"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

func (w *window) openKeymapImport() {
	s := &w.keyImport
	s.open, s.ready, s.busy, s.failure = true, false, false, nil
	s.result = keymapImportResult{}
	s.request = nil
	s.effect = nil
	s.format = "vscode"
	s.name.SetText("")
}

func (w *window) pickKeymapSource() {
	defer w.inv.Invalidate()
	s := &w.keyImport
	format := s.format
	pattern := "*.json;*.jsonc"
	if format == "idea" {
		pattern = "*.xml"
	}
	paths, err := app.OpenFiles(app.OpenFileOptions{Title: i18n.Shared(w.marketLanguage(), "desktop.keymapImport.chooseFile"), Filters: []app.FileFilter{{Name: i18n.Shared(w.marketLanguage(), "desktop.keymapImport.fileFilter"), Pattern: pattern}}})
	// log-exempt: 用户取消：关闭原生选择器不读取或保存快捷键。
	if errors.Is(err, app.ErrCanceled) {
		return
	}
	if err != nil {
		s.failure = keymapimport.ErrSource
		w.reportEssentialsFailure("keymap_import", keymapimport.ErrSource)
		return
	}
	if len(paths) == 0 || !s.open || s.busy {
		return
	}
	if s.name.Text() == "" {
		s.name.SetText(strings.TrimSuffix(filepath.Base(paths[0]), filepath.Ext(paths[0])))
	}
	state, current := w.keymapImportInputs()
	w.startKeymapImport(&keymapImportWork{Path: paths[0], Format: format, State: state, Current: current})
}

func (w *window) keymapImportFailure(err error) string {
	language := w.marketLanguage()
	if errors.Is(err, keymapimport.ErrChanged) || errors.Is(err, errKeymapImportStale) {
		return i18n.Shared(language, "desktop.keymapImport.changed")
	}
	var failure *core.Error
	if errors.As(err, &failure) {
		switch failure.Details {
		case "invalid_name":
			return i18n.Shared(language, "desktop.keymapSchemes.invalidName")
		case "duplicate_name":
			return i18n.Shared(language, "desktop.keymapSchemes.duplicateName")
		case "too_many_schemes":
			return i18n.Shared(language, "desktop.keymapSchemes.limit")
		}
	}
	return i18n.Shared(language, "desktop.keymapImport.failed")
}

func (w *window) keymapImportDialog(c ui.C) {
	s := &w.keyImport
	if !s.open {
		return
	}
	language := w.marketLanguage()
	ui.Modal(c.Part("keymap-import-dialog"), &s.open, i18n.Shared(language, "desktop.keymapImport.title"), ui.ModalSpec{Width: 620}, func() {
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				source := s.format
				if ui.Select(c.Part("source"), &source, []string{"vscode", "idea"}, func(value string) string {
					if value == "idea" {
						return i18n.Shared(language, "desktop.keymapImport.idea")
					}
					return i18n.Shared(language, "desktop.keymapImport.vscode")
				}).Width(230).Label(i18n.Shared(language, "desktop.keymapImport.source")).Disabled(s.busy).Changed() {
					s.format = source
					s.ready = false
					s.failure = nil
					s.result = keymapImportResult{}
				}
				w.infoButton(c, i18n.Shared(language, "desktop.keymapImport.help"))
				if ui.Button(c, i18n.Shared(language, "desktop.keymapImport.chooseFile")).Outline().Disabled(s.busy).Clicked() {
					c.After(w.pickKeymapSource)
				}
			})
			w.settingsRow(c, i18n.Shared(language, "desktop.keymapImport.name"), "", func() {
				ui.TextField(c, &s.name, i18n.Shared(language, "desktop.keymapImport.name"), "").Grow(1).MinWidth(0).Disabled(s.busy)
			})
			if s.busy {
				ui.Text(c, i18n.Shared(language, "desktop.keymapImport.working")).Color(w.pal.muted)
			}
			if s.failure != nil {
				ui.Wrap(c, w.keymapImportFailure(s.failure)).Color(w.pal.danger)
			}
			if !s.ready {
				return
			}
			p := s.result.Preview
			ui.Text(c, s.result.Snapshot.Path()).Ellipsis().Color(w.pal.muted)
			ui.Text(c, i18n.SharedFormat(language, "desktop.keymapImport.summary", map[string]string{"imported": strconv.Itoa(len(p.Imported)), "skipped": strconv.Itoa(len(p.Skipped)), "conflicts": strconv.Itoa(len(p.Conflicts))}))
			if p.Inherited {
				ui.Wrap(c, i18n.Shared(language, "desktop.keymapImport.inherited")).Color(w.pal.muted)
			}
			if len(p.Conflicts) > 0 {
				ui.Wrap(c, i18n.Shared(language, "desktop.keymapImport.conflicts")).Color(w.pal.danger)
			}
			count := len(p.Imported) + len(p.Displaced) + len(p.Conflicts) + len(p.Skipped)
			if count == 0 {
				ui.Text(c, i18n.Shared(language, "desktop.keymapImport.empty")).Color(w.pal.muted)
			} else {
				ui.List(c, &s.rows, count, func(row ui.ListRow) {
					row.Element.FillWidth().Height(46).Children(func() {
						ui.Column(row.C).FillWidth().Gap(3).Children(func() {
							title, detail := w.keymapImportRow(row.Index, p)
							ui.Text(row.C, title).FontSize(12).Ellipsis()
							ui.Text(row.C, detail).FontSize(11).Color(w.pal.muted).Ellipsis()
						})
					})
				}).Scrollbars().FillWidth().Height(float32(min(230, count*46))).Label(i18n.Shared(language, "desktop.keymapImport.preview"))
			}
		})
	}, func() {
		if ui.Button(c, w.text.Settings.Cancel).Outline().Clicked() {
			s.open = false
		}
		if ui.Button(c, i18n.Shared(language, "desktop.keymapImport.apply")).Disabled(s.busy || !s.ready || len(s.result.Preview.Imported) == 0 || len(s.result.Preview.Conflicts) > 0 || strings.TrimSpace(s.name.Text()) == "").Clicked() {
			previous := s.request
			w.startKeymapImport(&keymapImportWork{Format: s.format, Name: s.name.Text(), Snapshot: s.result.Snapshot, State: previous.State, Current: previous.Current, Apply: true})
		}
	})
	if !s.open {
		w.closeKeymapImport()
	}
}

func (w *window) keymapImportActionTitle(id string) string {
	if action, ok := shortcuts.Find(id); ok {
		return action.Title(w.text)
	}
	return id
}
func importKeys(keys []string) string {
	parts := make([]string, 0, len(keys))
	for _, text := range keys {
		if chord, ok := shortcuts.Decode(text); ok {
			parts = append(parts, shortcuts.Keycaps(chord))
		}
	}
	return strings.Join(parts, ", ")
}
func (w *window) keymapImportRow(index int, p keymapimport.Preview) (string, string) {
	language := w.marketLanguage()
	if index < len(p.Imported) {
		row := p.Imported[index]
		keys := importKeys(row.Keys)
		if len(row.Keys) == 0 {
			keys = i18n.Shared(language, "desktop.keymapImport.unbound")
		}
		return w.keymapImportActionTitle(row.ID), keys
	}
	index -= len(p.Imported)
	if index < len(p.Displaced) {
		row := p.Displaced[index]
		return w.keymapImportActionTitle(row.ID), i18n.SharedFormat(language, "desktop.keymapImport.displaced", map[string]string{"keys": importKeys(row.Keys)})
	}
	index -= len(p.Displaced)
	if index < len(p.Conflicts) {
		row := p.Conflicts[index]
		return w.keymapImportActionTitle(row.ID), i18n.SharedFormat(language, "desktop.keymapImport.conflictWith", map[string]string{"owner": w.keymapImportActionTitle(row.Owner), "key": importKeys([]string{row.Key})})
	}
	index -= len(p.Conflicts)
	row := p.Skipped[index]
	return row.Command, w.keymapImportSkipReason(row.Reason)
}
func (w *window) keymapImportSkipReason(reason string) string {
	language := w.marketLanguage()
	switch reason {
	case "conditional":
		return i18n.Shared(language, "desktop.keymapImport.skipConditional")
	case "sequence":
		return i18n.Shared(language, "desktop.keymapImport.skipSequence")
	case "arguments":
		return i18n.Shared(language, "desktop.keymapImport.skipArguments")
	case "removal":
		return i18n.Shared(language, "desktop.keymapImport.skipRemoval")
	case "unsupported_key", "unsupported_rule":
		return i18n.Shared(language, "desktop.keymapImport.skipKey")
	default:
		return i18n.Shared(language, "desktop.keymapImport.skipUnmapped")
	}
}
