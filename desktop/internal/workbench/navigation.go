package workbench

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

var (
	navigationField   = tree.ID(shellPage, "navigation-field")
	navigationDismiss = tree.ID(shellPage, "navigation-dismiss")
	navigationClose   = tree.ID(shellPage, "navigation-close")
	navigationCancel  = tree.ID(shellPage, "navigation-cancel")
	navigationConfirm = tree.ID(shellPage, "navigation-confirm")
)

type navigationView struct {
	input                           ui.Field
	project                         *project
	document                        int
	open, focus, selectAll, pending bool
	requestedFocus                  gfx.ID
	validated                       string
	target                          *core.NavigationTarget
	generation                      uint64
	cancel                          context.CancelFunc
	// A negative delay lets tests exercise the async path without a clock wait.
	delay time.Duration
}

// The macOS product uses Command-L; the Windows default keymap uses Control-G.
func isNavigationShortcut(platform string, event gfx.KeyEvent) bool {
	if platform == "darwin" {
		return event.Modifiers == gfx.ModifierMeta && strings.EqualFold(event.Text, "l")
	}
	return event.Modifiers == gfx.ModifierControl && strings.EqualFold(event.Text, "g")
}

func (a *App) openNavigation(p *project) bool {
	doc := p.selectedDocument(p.docs.group)
	if doc == nil || doc.view.IsComposing() {
		return false
	}
	v := &a.navigation
	if v.open {
		return true
	}
	line, column := doc.view.CaretUTF16()
	v.project, v.document, v.open = p, doc.id, true
	v.validated, v.target, v.pending = "", nil, false
	v.input.SetText(fmt.Sprintf("%d:%d", line+1, column+1))
	a.post(func(a *App) {
		if a.navigation.open && a.navigation.project == p && a.navigation.document == doc.id {
			a.navigation.focus, a.navigation.selectAll = true, true
		}
	})
	return true
}

func (a *App) closeNavigation() {
	v := &a.navigation
	if v.cancel != nil {
		v.cancel()
		v.cancel = nil
	}
	v.generation++
	if v.project == a.project && v.project != nil {
		if selected := v.project.selectedDocument(v.project.docs.group); selected != nil && selected.id == v.document {
			a.focusDocument(v.document)
		}
	}
	v.open, v.focus, v.selectAll, v.pending = false, false, false, false
	v.requestedFocus = gfx.ID{}
	v.project, v.target = nil, nil
}

func (a *App) syncNavigation(p *project) {
	v := &a.navigation
	value := v.input.Text()
	if value == v.validated {
		return
	}
	v.validated, v.target, v.pending = value, nil, false
	v.generation++
	gen := v.generation
	if v.cancel != nil {
		v.cancel()
	}
	ctx, cancel := context.WithCancel(p.ctx)
	v.cancel = cancel
	kernel := a.kernel
	delay := v.delay
	if delay == 0 {
		delay = 75 * time.Millisecond
	}
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				// log-exempt: 用户取消：输入改变或对话框关闭会取消等待。
				return nil
			}
		}
		operation, done := context.WithTimeout(ctx, kernelCallTimeout)
		defer done()
		target, err := kernel.ParseNavigationInput(operation, value)
		return func(a *App) {
			v := &a.navigation
			if !v.open || v.project != p || v.generation != gen || v.input.Text() != value {
				if err != nil && !errors.Is(err, context.Canceled) {
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_parse_navigation", err))
				}
				// log-exempt: 用户取消：旧输入的结果已被替换或对话框已关闭。
				return
			}
			v.cancel = nil
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_parse_navigation", err))
				return
			}
			v.target = target
			if v.pending {
				a.confirmNavigation(p)
			}
		}
	})
}

func (a *App) confirmNavigation(p *project) {
	v := &a.navigation
	if v.input.Text() != v.validated || v.target == nil {
		v.pending = true
		return
	}
	doc := p.selectedDocument(p.docs.group)
	if doc == nil || doc.id != v.document {
		a.closeNavigation()
		return
	}
	if doc.view.GoToNavigation(v.target.Line, v.target.Column, v.target.SelectsWholeLine) {
		a.closeNavigation()
	}
}

func (a *App) drawNavigation(f *ui.Frame, p *project) {
	v := &a.navigation
	if !v.open {
		return
	}
	if v.project != p || p.selectedDocument(p.docs.group) == nil || p.selectedDocument(p.docs.group).id != v.document {
		a.closeNavigation()
		return
	}
	a.syncNavigation(p)
	if v.focus {
		f.Canvas().RequestFocus(navigationField)
		v.focus = false
	}
	if !v.requestedFocus.IsZero() {
		f.Canvas().RequestFocus(v.requestedFocus)
		v.requestedFocus = gfx.ID{}
	}
	f.Popup().At(0, 0).Fill().HitWith(navigationDismiss, a.text.Errors.Dismiss, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Backdrop: true})
	bounds := f.Bounds()
	width, height := float32(340), float32(128)
	bg := gfx.RGB24(0xF5F5F6)
	if a.colors.Dark {
		bg = gfx.RGB24(0x1E2128)
	}
	f.Popup().At((bounds.Width-width)/2, (bounds.Height-height)/2).Size(width, height).
		Background(bg).Border(1, a.theme.Border).Radius(10).Shadow(gfx.ShadowMD).Children(func() {
		f.Row().FillWidth().Height(44).Items(ui.Start).PadX(8).PadY(9).Gap(9).Children(func() {
			for i := 0; i < 3; i++ {
				dot := f.Row().Size(14, 14).Radius(7).Background(gfx.RGB24(0x41444B))
				if i == 0 {
					dot = dot.HitWith(navigationClose, a.text.Errors.Dismiss, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true})
					if dot.Clicked() {
						a.closeNavigation()
					}
				}
			}
			f.Row().Width(0)
			f.Text(i18n.Shared(a.language(), "desktop.navigation.title")).FontSize(13).Color(a.colors.Subtle)
		})
		f.Row().FillWidth().Height(37).Items(ui.Center).PadX(16).Gap(8).Children(func() {
			f.Text(i18n.Shared(a.language(), "desktop.navigation.label")).FontSize(13).Color(a.colors.Text)
			f.Row().Grow(1).MinWidth(0).Height(24).Items(ui.Center).PadX(6).Border(1, a.colors.Line).Radius(6).Children(func() {
				f.FieldBase(&v.input, navigationField, i18n.Shared(a.language(), "desktop.navigation.label"), "").Grow(1).MinWidth(0).Height(22).FontSize(13).Color(a.colors.Text)
			})
		})
		f.Row().FillWidth().Height(44).Items(ui.Center).PadX(16).Gap(6).Children(func() {
			f.Row().Grow(1)
			if f.Button(navigationCancel, a.text.Settings.Cancel).Width(72).Height(28).Outline().Clicked() {
				a.closeNavigation()
			}
			if f.Button(navigationConfirm, a.text.Settings.OK).Width(72).Height(28).Disabled(v.target == nil || v.validated != v.input.Text()).Clicked() {
				a.confirmNavigation(p)
			}
		})
	})
	if v.selectAll {
		if input := a.fields(app.TextInputContext{ID: navigationField}); input != nil && input.Editor != nil {
			input.Editor.SetSelection(text.Range{Start: 0, End: input.Editor.RuneCount()})
			v.selectAll = false
		}
	}
}

func (a *App) navigationKey(p *project, event gfx.KeyEvent) gfx.EventResult {
	if event.Release {
		return gfx.EventResult{}
	}
	if event.Key == gfx.KeyTab && (event.Modifiers == 0 || event.Modifiers == gfx.ModifierShift) {
		ids := []gfx.ID{navigationField, navigationCancel}
		if a.navigation.target != nil && a.navigation.validated == a.navigation.input.Text() {
			ids = append(ids, navigationConfirm)
		}
		index := 0
		for i, id := range ids {
			if id == event.Target {
				index = i
				break
			}
		}
		if event.Modifiers == gfx.ModifierShift {
			index = (index + len(ids) - 1) % len(ids)
		} else {
			index = (index + 1) % len(ids)
		}
		a.navigation.requestedFocus = ids[index]
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if event.Modifiers != 0 {
		return gfx.EventResult{}
	}
	if event.Target == navigationField {
		input := a.fields(app.TextInputContext{ID: navigationField})
		if input != nil && input.Editor != nil {
			if _, composing := input.Editor.Composition(); composing {
				return gfx.EventResult{}
			}
		}
	}
	switch event.Key {
	case gfx.KeyEscape:
		a.closeNavigation()
	case gfx.KeyEnter:
		a.syncNavigation(p)
		a.confirmNavigation(p)
	default:
		return gfx.EventResult{}
	}
	return gfx.EventResult{Handled: true, Repaint: true}
}
