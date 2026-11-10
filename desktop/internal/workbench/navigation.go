package workbench

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// navigationField names the line and column field, so the dialog can select its
// text when it opens.
var navigationField = tree.ID(shellPage, "navigation-field")

type navigationView struct {
	input                    ui.Field
	project                  *project
	document                 int
	open, selectAll, pending bool
	validated                string
	target                   *core.NavigationTarget
	generation               uint64
	cancel                   context.CancelFunc
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
	v.selectAll = true
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
	v.open, v.selectAll, v.pending = false, false, false
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
