package settingswindow

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

const (
	fileTypeScopeGlobal  = "global"
	fileTypeScopeProject = "project"
)

type fileTypeMappingsWork struct {
	source FileTypeMappingsSource
	base   FileTypeMappingsSnapshot
	save   *FileTypeMappingsSnapshot
}

type fileTypeMappingsDraft struct {
	ready, busy, dirty, stale, saved bool
	failure                          string
	scope                            string
	patternField                     ui.Field
	langPick                         string
	customList                       ui.ListState
	builtinList                      ui.ListState
	snapshot                         FileTypeMappingsSnapshot
	working                          FileTypeMappingsSnapshot
	work                             *fileTypeMappingsWork
	effect                           *ui.EffectState[FileTypeMappingsSaveResult, *fileTypeMappingsWork]
}

func (w *window) startFileTypeMappings(work *fileTypeMappingsWork) {
	d := &w.fileTypeDraft
	if d.busy || w.sess.finished.Load() {
		return
	}
	if d.effect == nil {
		d.effect = ui.NewEffectKeyed[FileTypeMappingsSaveResult, *fileTypeMappingsWork](func(ctx context.Context, req *fileTypeMappingsWork) (FileTypeMappingsSaveResult, error) {
			ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			defer cancel()
			if req.source == nil {
				return FileTypeMappingsSaveResult{}, errors.New("file type mappings source unavailable")
			}
			if req.save == nil {
				snap, err := req.source.Load(ctx)
				return FileTypeMappingsSaveResult{Snapshot: snap}, err
			}
			return req.source.Save(ctx, req.base, *req.save)
		}).Sequential()
	}
	d.work = work
	d.busy = true
	d.failure = ""
	w.inv.Invalidate()
}

func (w *window) takeFileTypeMappings() {
	d := &w.fileTypeDraft
	if d.effect == nil {
		return
	}
	res, err, ok := d.effect.Take()
	if !ok {
		return
	}
	wasSave := d.work != nil && d.work.save != nil
	d.busy = false
	lang := w.marketLanguage()
	if err != nil {
		if wasSave {
			d.saved = false
			if errors.Is(err, ErrFileTypeMappingsConflict) {
				d.stale = true
				d.failure = i18n.Shared(lang, "desktop.fileTypeMappings.conflict")
			} else {
				d.failure = i18n.Shared(lang, "desktop.fileTypeMappings.saveFailed")
			}
			return
		}
		d.failure = i18n.Shared(lang, "desktop.fileTypeMappings.loadFailed")
		w.reportEssentialsFailure("file_type_mappings", err)
		return
	}
	if len(res.Issues) > 0 {
		d.saved = false
		d.failure = formatFileTypeMappingIssue(lang, res.Issues[0])
		return
	}
	d.snapshot = cloneFileTypeMappingsSnapshot(res.Snapshot)
	d.working = cloneFileTypeMappingsSnapshot(res.Snapshot)
	d.ready = true
	d.dirty = false
	d.stale = false
	d.failure = ""
	d.saved = wasSave
	if d.langPick == "" && len(d.working.KnownLanguageIDs) > 0 {
		if slices.Contains(d.working.KnownLanguageIDs, "toml") {
			d.langPick = "toml"
		} else {
			d.langPick = d.working.KnownLanguageIDs[0]
		}
	}
}

func formatFileTypeMappingIssue(lang i18n.Language, issue core.FileTypeMappingIssue) string {
	scopeLabel := i18n.Shared(lang, "desktop.fileTypeMappings.scopeGlobal")
	if issue.Scope == fileTypeScopeProject {
		scopeLabel = i18n.Shared(lang, "desktop.fileTypeMappings.scopeProject")
	}
	switch issue.Code {
	case "invalid_pattern":
		return i18n.SharedFormat(lang, "desktop.fileTypeMappings.invalidPattern", map[string]string{
			"scope": scopeLabel, "pattern": issue.Pattern,
		})
	case "invalid_language":
		return i18n.SharedFormat(lang, "desktop.fileTypeMappings.invalidLanguage", map[string]string{
			"scope": scopeLabel, "language": issue.LanguageID,
		})
	case "unknown_language":
		return i18n.SharedFormat(lang, "desktop.fileTypeMappings.unknownLanguage", map[string]string{
			"scope": scopeLabel, "language": issue.LanguageID,
		})
	case "too_many_entries":
		return i18n.SharedFormat(lang, "desktop.fileTypeMappings.tooManyEntries", map[string]string{
			"scope": scopeLabel,
		})
	default:
		return i18n.Shared(lang, "desktop.fileTypeMappings.saveFailed")
	}
}

func (d *fileTypeMappingsDraft) activeScope() string {
	if d.scope == fileTypeScopeProject {
		return fileTypeScopeProject
	}
	return fileTypeScopeGlobal
}

func (d *fileTypeMappingsDraft) activeSlicePtr() *[]core.FileTypeMapping {
	if d.activeScope() == fileTypeScopeProject {
		return &d.working.Project
	}
	return &d.working.Global
}

func (d *fileTypeMappingsDraft) scopeEditable() bool {
	if d.busy || d.stale || !d.ready {
		return false
	}
	return d.activeScope() == fileTypeScopeGlobal || d.working.HasWorkspace
}

func (d *fileTypeMappingsDraft) customOverriddenSet() map[string]bool {
	overridden := make(map[string]bool, len(d.working.Global)+len(d.working.Project))
	for _, m := range d.working.Global {
		overridden[strings.ToLower(strings.TrimSpace(m.Pattern))] = true
	}
	for _, m := range d.working.Project {
		overridden[strings.ToLower(strings.TrimSpace(m.Pattern))] = true
	}
	return overridden
}

func (w *window) fileTypeMappingsPage(c ui.C) {
	d := &w.fileTypeDraft
	language := w.marketLanguage()
	if d.scope == "" {
		d.scope = fileTypeScopeGlobal
	}
	if d.work == nil {
		w.startFileTypeMappings(&fileTypeMappingsWork{source: w.ctrl.opts.FileTypeMappings})
	}
	w.pageScroll(c, pageFileTypeMappings, func() {
		w.card(c, i18n.Shared(language, "desktop.fileTypeMappings.pageTitle"), i18n.Shared(language, "desktop.fileTypeMappings.help"), func() {
			if !d.ready && d.busy {
				ui.Text(c, i18n.Shared(language, "native.loading")).Muted().FontSize(12)
				return
			}
			w.fileTypeScopeHeader(c, d, language)
			w.fileTypeAddRow(c, d, language)
			w.fileTypeCustomList(c, d, language)
			w.fileTypeActionBar(c, d, language)
		})
		w.fileTypeBuiltinsCard(c, d, language)
	})
}

func (w *window) fileTypeScopeHeader(c ui.C, d *fileTypeMappingsDraft, language i18n.Language) {
	scopeLabel := func(scope string) string {
		if scope == fileTypeScopeProject {
			return i18n.Shared(language, "desktop.fileTypeMappings.scopeProject")
		}
		return i18n.Shared(language, "desktop.fileTypeMappings.scopeGlobal")
	}
	ui.Row(c).FillWidth().Items(ui.Center).Gap(10).Children(func() {
		ui.Choice(c.Part("scope"), &d.scope, []string{fileTypeScopeGlobal, fileTypeScopeProject}, scopeLabel).Width(280).Shrink(1)
		ui.Spacer(c)
		if ui.Button(c.Part("reload"), i18n.Shared(language, "desktop.fileTypeMappings.refresh")).Outline().Small().Disabled(d.busy).Clicked() {
			w.startFileTypeMappings(&fileTypeMappingsWork{source: w.ctrl.opts.FileTypeMappings})
		}
	})
	sourcePath := d.working.GlobalConfigPath
	if d.activeScope() == fileTypeScopeProject {
		if !d.working.HasWorkspace {
			ui.Wrap(c, i18n.Shared(language, "desktop.fileTypeMappings.noWorkspace")).FontSize(12).Color(w.pal.muted)
			return
		}
		sourcePath = d.working.ProjectConfigPath
	}
	if sourcePath != "" {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.fileTypeMappings.sourcePath")+":").FontSize(11).Color(w.pal.muted).Shrink(0)
			ui.Text(c, sourcePath).FontSize(11).Color(w.pal.muted).Ellipsis().Grow(1)
		})
	}
}

func (w *window) fileTypeAddRow(c ui.C, d *fileTypeMappingsDraft, language i18n.Language) {
	editable := d.scopeEditable()
	choices := d.working.KnownLanguageIDs
	if len(choices) == 0 {
		choices = []string{"toml", "json", "jsonc", "yaml", "ini", "plaintext"}
	}
	if d.langPick == "" {
		d.langPick = choices[0]
	}
	placeholder := i18n.Shared(language, "desktop.fileTypeMappings.patternPlaceholder")
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.TextField(c.Part("pattern"), &d.patternField, placeholder, placeholder).
			Grow(1).MinWidth(140).Disabled(!editable)
		ui.Select(c.Part("add-language"), &d.langPick, choices, func(id string) string { return id }).
			Width(150).Label(i18n.Shared(language, "desktop.fileTypeMappings.languageLabel")).Disabled(!editable)
		canAdd := editable && strings.TrimSpace(d.patternField.Text()) != "" && d.langPick != ""
		if ui.Button(c.Part("add-rule"), i18n.Shared(language, "desktop.fileTypeMappings.add")).Outline().Disabled(!canAdd).Clicked() {
			pattern := strings.TrimSpace(d.patternField.Text())
			targetLang := d.langPick
			listPtr := d.activeSlicePtr()
			updated := false
			for i := range *listPtr {
				if strings.EqualFold((*listPtr)[i].Pattern, pattern) {
					(*listPtr)[i].Pattern = pattern
					(*listPtr)[i].LanguageID = targetLang
					updated = true
					break
				}
			}
			if !updated {
				*listPtr = append(*listPtr, core.FileTypeMapping{Pattern: pattern, LanguageID: targetLang})
			}
			d.patternField.SetText("")
			d.dirty = true
			d.saved = false
			d.failure = ""
			w.inv.Invalidate()
		}
	})
}

func (w *window) fileTypeCustomList(c ui.C, d *fileTypeMappingsDraft, language i18n.Language) {
	listPtr := d.activeSlicePtr()
	entries := *listPtr
	if len(entries) == 0 {
		if d.activeScope() == fileTypeScopeGlobal || d.working.HasWorkspace {
			ui.Text(c, i18n.Shared(language, "desktop.fileTypeMappings.emptyCustom")).FontSize(12).Color(w.pal.muted)
		}
		return
	}
	editable := d.scopeEditable()
	choices := d.working.KnownLanguageIDs
	if len(choices) == 0 {
		choices = []string{"toml", "json", "jsonc", "yaml", "ini", "plaintext"}
	}
	listHeight := float32(min(len(entries), 6)*34 + 4)
	ui.List(c.Part("custom-mappings"), &d.customList, len(entries), func(row ui.ListRow) {
		index := row.Index
		entry := entries[index]
		rowChoices := choices
		if !slices.Contains(rowChoices, entry.LanguageID) {
			rowChoices = append(slices.Clone(choices), entry.LanguageID)
		}
		selectedLang := entry.LanguageID
		row.Element.FillWidth().Children(func() {
			ui.Row(row.C).FillWidth().Height(32).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(row.C, entry.Pattern).FontSize(12).Color(w.pal.text).Ellipsis().Grow(1).MinWidth(0)
				if ui.Select(row.C.Part("rule-lang"), &selectedLang, rowChoices, func(id string) string { return id }).
					Width(150).Label(i18n.Shared(language, "desktop.fileTypeMappings.languageLabel")).Disabled(!editable).Changed() {
					nextLang := selectedLang
					c.After(func() {
						if index < len(*listPtr) {
							(*listPtr)[index].LanguageID = nextLang
							d.dirty = true
							d.saved = false
							d.failure = ""
						}
					})
				}
				if ui.Button(row.C.Part("remove-rule"), i18n.Shared(language, "desktop.fileTypeMappings.remove")).
					Icon(icons.X).IconOnly().Ghost().Size(24, 24).Disabled(!editable).Clicked() {
					c.After(func() {
						if index < len(*listPtr) {
							*listPtr = slices.Delete(*listPtr, index, index+1)
							d.dirty = true
							d.saved = false
							d.failure = ""
						}
					})
				}
			})
		})
	}).Scrollbars().FillWidth().Height(listHeight).Label(i18n.Shared(language, "desktop.fileTypeMappings.pageTitle"))
}

func (w *window) fileTypeActionBar(c ui.C, d *fileTypeMappingsDraft, language i18n.Language) {
	if d.failure != "" {
		ui.Wrap(c, d.failure).FontSize(12).Color(w.pal.danger)
	} else if d.saved {
		ui.Wrap(c, i18n.Shared(language, "desktop.fileTypeMappings.saved")).FontSize(12).Color(w.pal.muted)
	}
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		if ui.Button(c.Part("save"), i18n.Shared(language, "desktop.fileTypeMappings.save")).
			Disabled(!d.ready || d.busy || d.stale || !d.dirty).Clicked() {
			saveSnap := cloneFileTypeMappingsSnapshot(d.working)
			w.startFileTypeMappings(&fileTypeMappingsWork{
				source: w.ctrl.opts.FileTypeMappings,
				base:   d.snapshot,
				save:   &saveSnap,
			})
		}
		if ui.Button(c.Part("discard"), i18n.Shared(language, "desktop.fileTypeMappings.discard")).Outline().
			Disabled(!d.ready || d.busy || !d.dirty).Clicked() {
			d.working = cloneFileTypeMappingsSnapshot(d.snapshot)
			d.dirty = false
			d.failure = ""
			d.saved = false
			w.inv.Invalidate()
		}
	})
}

func (w *window) fileTypeBuiltinsCard(c ui.C, d *fileTypeMappingsDraft, language i18n.Language) {
	if !d.ready || len(d.working.Builtins) == 0 {
		return
	}
	overridden := d.customOverriddenSet()
	w.card(c, i18n.Shared(language, "desktop.fileTypeMappings.builtinsTitle"), "", func() {
		builtins := d.working.Builtins
		listHeight := float32(min(len(builtins), 8)*28 + 4)
		ui.List(c.Part("builtin-mappings"), &d.builtinList, len(builtins), func(row ui.ListRow) {
			item := builtins[row.Index]
			isOverridden := overridden[strings.ToLower(item.Pattern)]
			row.Element.FillWidth().Children(func() {
				ui.Row(row.C).FillWidth().Height(26).Items(ui.Center).Gap(8).Children(func() {
					ui.Text(row.C, item.Pattern).FontSize(12).Color(w.pal.text).Ellipsis().Grow(1).MinWidth(0)
					if isOverridden {
						ui.Row(row.C).Shrink(0).PadSides(2, 6, 2, 6).Radius(4).Background(w.pal.sidebar).Items(ui.Center).Children(func() {
							ui.Text(row.C, i18n.Shared(language, "desktop.fileTypeMappings.overridden")).FontSize(10).Color(w.pal.muted)
						})
					}
					ui.Text(row.C, item.LanguageID).FontSize(12).Color(w.pal.muted).Width(88).Ellipsis().Shrink(0)
				})
			})
		}).Scrollbars().FillWidth().Height(listHeight).Label(i18n.Shared(language, "desktop.fileTypeMappings.builtinsTitle"))
	})
}
