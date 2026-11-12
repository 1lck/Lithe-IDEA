package workbench

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// debugExceptionInfo declares the exception info button of the exceptions section and the account it
// fetched. The button shows while the thread is stopped and the adapter negotiated the request; the
// answer is kept until the thread resumes.
func (a *App) debugExceptionInfo(c ui.C, p *project) {
	d := &p.debug
	if d.state != "paused" || d.activeSession() == nil || d.pausedThread == nil || d.capabilities == nil || !d.capabilities.SupportsExceptionInfoRequest {
		return
	}
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		if ui.Button(c, i18n.Shared(a.language(), "desktop.debug.exceptionInfo")).Outline().Clicked() {
			c.After(func() { a.requestExceptionInfo(p) })
		}
	})
	info := d.exception
	if info == nil {
		return
	}
	ui.Column(c).FillWidth().Gap(2).PadX(8).Children(func() {
		ui.Text(c, info.ExceptionID).FontSize(12).Weight(gfx.WeightMedium).Color(a.theme.Danger).Ellipsis()
		if info.Description != "" {
			ui.Wrap(c, info.Description).FontSize(12).Color(a.colors.Text)
		}
		if message := info.Details.Message; message != "" && message != info.Description {
			ui.Wrap(c, message).FontSize(12).Color(a.colors.Text)
		}
		for _, inner := range info.Details.InnerExceptions {
			ui.Text(c, "↳ "+strings.TrimSpace(inner.FullTypeName+" "+inner.Message)).FontSize(11.5).Color(a.colors.Subtle).Ellipsis()
		}
		if stack := strings.TrimSpace(info.Details.StackTrace); stack != "" {
			for _, line := range strings.Split(stack, "\n") {
				ui.Text(c, line).FontSize(11.5).Color(a.colors.Subtle).Mono().Ellipsis()
			}
		}
	})
}

// requestExceptionInfo asks the adapter for the exception the paused thread stopped on.
func (a *App) requestExceptionInfo(p *project) {
	if p == nil || p.debug.activeSession() == nil || p.debug.pausedThread == nil {
		return
	}
	thread := *p.debug.pausedThread
	a.debugOperation(p, "exceptionInfo", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID: session.id, OperationID: operationID, Kind: "exceptionInfo", ThreadID: &thread,
		})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		if result.Kind != "exceptionInfo" || result.ExceptionInfo == nil {
			return
		}
		p.debug.exception = result.ExceptionInfo
	}})
}
