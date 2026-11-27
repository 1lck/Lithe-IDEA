package workbench

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

type welcomeTagEdit struct {
	path     string
	original []string
	field    ui.Field
	saving   bool
	conflict bool
}

func (a *App) welcomeProjection() core.RecentProjectsResult {
	w := &a.welcome
	query, start := w.search.Text(), &a.recent[0]
	if w.projectionValid && w.projectionStart == start && w.projectedQuery == query && w.projectedTag == w.tag {
		return w.projection
	}
	w.projectionValid, w.projectionStart, w.projectedQuery, w.projectedTag = true, start, query, w.tag
	ctx, cancel := context.WithTimeout(a.operationContext(context.Background()), kernelCallTimeout)
	defer cancel()
	project := func(tag string) (core.RecentProjectsResult, error) {
		return a.kernel.ReduceRecentProjects(ctx, a.recent, core.FilterRecent(query, tag), 0)
	}
	result, err := project(w.tag)
	if err == nil && w.tag != "" {
		w.tag, w.projectedTag = result.SelectedTag, result.SelectedTag
		if w.tag == "" {
			result, err = project("")
		}
	}
	if err != nil {
		a.operationFailed("workspace_recent_reduce", documentLogError(err))
		// A filter failure should not hide the recent projects.
		result.Visible = make([]int, len(a.recent))
		for i := range result.Visible {
			result.Visible[i] = i
		}
	}
	w.projection = result
	return result
}

func (a *App) welcomeTagFilter(c ui.C, tags []string) {
	if len(tags) == 0 {
		return
	}
	w := &a.welcome
	lang := a.language()
	ui.Row(c).FillWidth().Shrink(0).PadX(22).PadY(5).Children(func() {
		ui.Select(c, &w.tag, append([]string{""}, tags...), func(tag string) string {
			if tag == "" {
				return i18n.Shared(lang, "desktop.welcome.allTags")
			}
			return tag
		}).Label(i18n.Shared(lang, "desktop.welcome.filterTags")).Width(160)
	})
}

func (a *App) editWelcomeTags(path string) {
	for _, entry := range a.recent {
		if entry.Path == path {
			a.welcome.tagEdit = welcomeTagEdit{path: path, original: slices.Clone(entry.Tags)}
			a.welcome.tagEdit.field.SetText(strings.Join(entry.Tags, ", "))
			return
		}
	}
}

func (a *App) saveWelcomeTags() {
	edit := &a.welcome.tagEdit
	if edit.path == "" || edit.saving || edit.conflict {
		return
	}
	edit.saving = true
	tags := strings.FieldsFunc(edit.field.Text(), func(r rune) bool { return r == ',' || r == '，' })
	a.changeRecent(core.SetRecentTagsFrom(edit.path, tags, edit.original), func(_ core.RecentProjectsResult, err error) {
		if err == nil {
			*edit = welcomeTagEdit{}
		} else {
			edit.saving = false
			var coreErr *core.Error
			edit.conflict = errors.As(err, &coreErr) && coreErr.Code == core.CodeRecentProjectTagsChanged
		}
	})
}

func (a *App) welcomeTagsDialog(c ui.C) {
	edit := &a.welcome.tagEdit
	if edit.path == "" {
		return
	}
	lang := a.language()
	open, submitted := true, false
	closed := ui.Modal(c, &open, i18n.Shared(lang, "desktop.welcome.editTags"), ui.ModalSpec{Width: 400}, func() {
		label := i18n.Shared(lang, "desktop.welcome.tagsInput")
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			ui.Text(c, label).Muted()
			submitted = ui.TextField(c, &edit.field, label, "").AutoFocus().FillWidth().Disabled(edit.saving).Submitted()
			if edit.conflict {
				ui.Wrap(c, i18n.Shared(lang, "desktop.welcome.tagsChanged")).FillWidth().Color(a.colors.Warning)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.git.cancel")).Outline().Disabled(edit.saving).Clicked() {
			c.After(func() { *edit = welcomeTagEdit{} })
		}
		if ui.Button(c, i18n.Shared(lang, "ui.save")).Disabled(edit.saving || edit.conflict).Clicked() {
			c.After(a.saveWelcomeTags)
		}
	})
	if submitted {
		c.After(a.saveWelcomeTags)
	}
	if closed && !edit.saving {
		c.After(func() { *edit = welcomeTagEdit{} })
	}
}
