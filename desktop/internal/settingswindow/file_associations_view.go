package settingswindow

import (
	"context"
	"errors"
	"runtime"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fileassociations"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

type associationRequest struct {
	action   string
	baseline fileassociations.State
	selected []string
	label    string
	ctx      context.Context
}

type associationResult struct {
	state fileassociations.State
	err   error
}

type associationRegistration struct {
	effect  *ui.EffectState[associationResult, *associationRequest]
	request *associationRequest
	state   fileassociations.State
	list    ui.ListState
	picked  map[string]bool
	err     error
	loaded  bool
	applied bool
}

func (w *window) declareAssociations(c ui.C) {
	s := &w.associations
	if s.effect != nil && s.request != nil {
		ui.Effect(c, s.effect, s.request)
	}
}

func (w *window) requestAssociations(action string, selected []string) {
	ctx := context.Background()
	if w.ctrl.opts.AssociationAction != nil {
		ctx = w.ctrl.opts.AssociationAction(ctx, action)
	}
	s := &w.associations
	s.request = &associationRequest{
		action: action, baseline: s.state, selected: selected, ctx: ctx,
		label: i18n.Shared(w.marketLanguage(), "desktop.associations.openWith"),
	}
	s.applied = false
}

func (w *window) associationsCard(c ui.C) {
	manager := w.ctrl.opts.FileAssociations
	if manager == nil {
		return
	}
	s := &w.associations
	language := w.marketLanguage()
	if s.effect == nil {
		s.picked = make(map[string]bool)
		s.effect = ui.NewEffectKeyed[associationResult, *associationRequest](func(parent context.Context, request *associationRequest) (associationResult, error) {
			// Effect cancellation owns the job lifetime; the operation context carries logs.
			ctx, cancel := context.WithTimeout(request.ctx, 30*time.Second)
			stop := context.AfterFunc(parent, cancel)
			defer stop()
			defer cancel()
			var result associationResult
			if request.action == "apply" {
				result.state, result.err = manager.Apply(ctx, request.baseline, request.selected, request.label)
			} else {
				result.state, result.err = manager.Read(ctx)
			}
			if result.err != nil && !errors.Is(result.err, context.Canceled) && w.ctrl.opts.AssociationError != nil {
				w.ctrl.opts.AssociationError(ctx, result.err)
			}
			// log-exempt: 用户取消：设置窗口关闭时 Effect 撤销尚未结束的工作。
			return result, nil
		})
		s.request = &associationRequest{action: "read", ctx: context.Background()}
	}
	if result, effectErr, ok := s.effect.Take(); ok {
		s.err = errors.Join(result.err, effectErr)
		s.applied = s.request.action == "apply" && s.err == nil
		s.request = nil
		if result.state.Formats != nil {
			s.state, s.loaded = result.state, true
		}
	}
	busy := s.request != nil
	help := i18n.Shared(language, "desktop.associations.helpMac")
	apply := i18n.Shared(language, "desktop.associations.applyMac")
	if runtime.GOOS == "windows" {
		help, apply = i18n.Shared(language, "desktop.associations.helpWindows"), i18n.Shared(language, "desktop.associations.applyWindows")
	}
	w.card(c, i18n.Shared(language, "desktop.associations.title"), help, func() {
		ui.Row(c).FillWidth().Height(30).Items(ui.Center).Gap(8).Children(func() {
			if ui.Button(c.Part("association-all"), i18n.Shared(language, "desktop.associations.selectAll")).Ghost().Disabled(busy || !s.loaded).Clicked() {
				c.After(func() {
					for _, format := range s.state.Formats {
						s.picked[format.Extension] = true
					}
				})
			}
			if ui.Button(c.Part("association-none"), i18n.Shared(language, "desktop.associations.clearSelection")).Ghost().Disabled(busy || !s.loaded).Clicked() {
				c.After(func() { clear(s.picked) })
			}
			ui.Spacer(c)
			if busy {
				ui.Text(c, i18n.Shared(language, "native.loading")).FontSize(12).Color(w.pal.muted)
			}
			if ui.Button(c.Part("association-refresh"), i18n.Shared(language, "desktop.associations.refresh")).Ghost().Disabled(busy).Clicked() {
				c.After(func() { w.requestAssociations("refresh", nil) })
			}
		})
		ui.Row(c).FillWidth().Height(24).Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.associations.format")).WidthPercent(30).Ellipsis().Color(w.pal.muted).FontSize(11)
			ui.Text(c, i18n.Shared(language, "desktop.associations.language")).WidthPercent(22).Ellipsis().Color(w.pal.muted).FontSize(11)
			ui.Text(c, i18n.Shared(language, "desktop.associations.currentDefault")).Grow(1).Ellipsis().Color(w.pal.muted).FontSize(11)
		})
		ui.List(c.Part("association-formats"), &s.list, len(s.state.Formats), func(row ui.ListRow) {
			format := s.state.Formats[row.Index]
			handler := s.state.Handlers[row.Index]
			row.Element.FillWidth().Children(func() {
				ui.Row(row.C).FillWidth().Height(28).Items(ui.Center).Gap(8).Children(func() {
					ui.Row(row.C).WidthPercent(30).Shrink(0).Children(func() {
						picked := s.picked[format.Extension]
						if ui.Checkbox(row.C.Key(format.Extension), &picked, format.Extension).Disabled(busy).Changed() {
							s.picked[format.Extension] = picked
						}
					})
					ui.Text(row.C, format.Language).WidthPercent(22).Ellipsis().FontSize(12).Color(w.pal.muted)
					name := handler.DefaultName
					if name == "" {
						name = handler.DefaultID
					}
					if name == "" {
						name = i18n.Shared(language, "desktop.associations.noDefault")
					}
					if handler.IsDefault {
						name = i18n.Shared(language, "desktop.associations.litheDefault")
					}
					cell := row.C.Part("default-application")
					ui.Row(cell).Hit(ui.ID(cell), name).Grow(1).MinWidth(0).Tooltip(name).Children(func() {
						ui.Text(row.C, name).Ellipsis().FontSize(12).Color(w.pal.text)
					})
				})
			})
		}).Scrollbars().FillWidth().Height(224).Label(i18n.Shared(language, "desktop.associations.formats"))
		var selected []string
		for _, format := range s.state.Formats {
			if s.picked[format.Extension] {
				selected = append(selected, format.Extension)
			}
		}
		ui.Row(c).FillWidth().Height(34).Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, i18n.SharedFormat(language, "desktop.associations.selected", map[string]string{"count": strconv.Itoa(len(selected))})).FontSize(12).Color(w.pal.muted).Grow(1)
			if ui.Button(c.Part("association-apply"), apply).Outline().Disabled(busy || !s.loaded || !s.state.Available || len(selected) == 0).Clicked() {
				c.After(func() { w.requestAssociations("apply", selected) })
			}
		})
		if s.loaded && !s.state.Available {
			ui.Wrap(c, i18n.Shared(language, "desktop.associations.requiresInstalled")).FontSize(12).Color(w.pal.muted)
		}
		if s.applied {
			message := i18n.Shared(language, "desktop.associations.appliedMac")
			if runtime.GOOS == "windows" {
				message = i18n.Shared(language, "desktop.associations.appliedWindows")
			}
			ui.Wrap(c, message).FontSize(12).Color(w.pal.muted)
		}
		if s.err != nil {
			message := i18n.Shared(language, "desktop.associations.failed")
			if errors.Is(s.err, fileassociations.ErrConflict) {
				message = i18n.Shared(language, "desktop.associations.conflict")
			}
			ui.Wrap(c, message).FontSize(12).Color(w.pal.danger)
		}
	})
}
