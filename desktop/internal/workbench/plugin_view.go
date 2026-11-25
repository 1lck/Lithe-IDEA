package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginview"
	"github.com/vivaui/viva/ui"
)

// A plugin tool window with a view function (API-13) shows a plugin view: the plugin's
// backend answers each view event with the nodes to draw, Core checks the answer, and the
// workbench draws it with its own controls (pluginview). The view shows while the window's
// body is declared: the first paint that declares it opens it, and the first paint that does
// not, because the window closed, the project closed or the plugin changed, closes it. What the
// view shows lives in memory only and ends with the showing; nothing is saved for it.

// pluginViewState is one tool window's view in the open project.
type pluginViewState struct {
	window pluginservice.ToolWindow
	// language is the interface language the view was opened in: the plugin returns its
	// text in it, so a language change opens the view anew.
	language i18n.Language
	session  *pluginview.Session
	images   *pluginview.Images
	host     pluginview.Host
	// shown says this paint declared the window's body.
	shown bool
}

// pluginViewOperation is the operation a tool window view's failures are logged under: a call
// that failed and a view the window cannot read, both drawn in the view with a retry. A canvas
// image it cannot read is drawn without and logged as background work.
const pluginViewOperation = "plugin_view"

// viewCallFailed logs a view call that failed, from the call's goroutine, under operation: the
// view draws the failure. A call the view's closing or the project's cancelled is not one.
func (a *App) viewCallFailed(ctx context.Context, operation string, err error) {
	// log-exempt: 用户取消：视图关闭或项目关闭时取消的调用不是失败。
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	a.operationFailedIn(ctx, operation, err)
}

// pluginViewKey names a tool window's view among the project's.
func pluginViewKey(window *pluginservice.ToolWindow) string {
	return window.PluginID + "\x00" + window.ID
}

// close ends the showing and drops the images it read.
func (v *pluginViewState) close() {
	v.session.Close()
	v.images.Close()
}

// pluginView is the view of window in p, made the first time the window shows and made anew
// when the plugin's installed manifest, package or view function, or the interface language,
// changed under it.
func (a *App) pluginView(p *project, window *pluginservice.ToolWindow) *pluginViewState {
	key := pluginViewKey(window)
	if v := p.pluginViews[key]; v != nil {
		if v.window.View == window.View && v.window.Package == window.Package && bytes.Equal(v.window.Manifest, window.Manifest) && v.language == a.language() {
			return v
		}
		v.close()
	}
	if p.pluginViews == nil {
		p.pluginViews = map[string]*pluginViewState{}
	}
	// The wake is taken now: the window's invalidator is installed before the first paint and
	// is safe to call from the call's goroutine.
	wake := a.invalidator.Invalidate
	plugins, root, current, language, ctx := a.plugins, p.root, *window, a.language(), p.ctx
	imageFailed := func(err error) { a.backgroundFailedIn(ctx, "plugin_view_image", err) }
	v := &pluginViewState{window: current, language: language, images: pluginview.NewImages(current.Package, wake, imageFailed)}
	v.session = pluginview.NewSession(pluginview.Options{
		Call: func(ctx context.Context, event, view json.RawMessage, closing bool) (json.RawMessage, bool, error) {
			drawn, changed, err := plugins.CallView(ctx, pluginservice.ToolWindowViewCall(current, root, event, view, closing))
			a.viewCallFailed(ctx, pluginViewOperation, err)
			return drawn, changed, err
		},
		Params:  func() map[string]any { return map[string]any{"language": language.Code()} },
		Wake:    wake,
		Failed:  func(err error) { a.operationFailed(pluginViewOperation, err) },
		Context: ctx,
		Page:    a.plugins.PluginWorkflow,
		Watch: func(instance string, refresh func()) func() {
			return plugins.WatchView(current.PluginID, instance, refresh)
		},
		Go: func(work func()) {
			a.tasks.running.Add(1)
			go func() {
				defer a.tasks.running.Done()
				work()
			}()
		},
	})
	v.host = pluginview.Host{
		Icon:   pluginview.HostIcon,
		Images: v.images,
		Info:   a.pluginViewInfo,
	}
	p.pluginViews[key] = v
	return v
}

// pluginViewBody declares a plugin tool window's body: its view, opened the first time.
func (a *App) pluginViewBody(c ui.C, p *project, window *pluginservice.ToolWindow) {
	v := a.pluginView(p, window)
	v.shown = true
	v.session.Open()
	v.host.Palette, v.host.Language = a.pluginViewPalette(), a.language()
	ui.Column(c.Key("plugin-view")).Fill().Background(a.colors.Editor).Children(func() {
		pluginview.Draw(c, v.session, &v.host, true)
	})
}

// pluginViewInfo is the workbench's ⓘ for a view's info text, a hover tip as elsewhere.
func (a *App) pluginViewInfo(c ui.C, text string) {
	ui.Button(c, i18n.Shared(a.language(), "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().
		Size(18, 18).Shrink(0).Tooltip(text)
}

// pluginViewPalette maps the workbench's look onto the tokens a view names, so a view reads
// as part of the window in the light and the dark theme.
func (a *App) pluginViewPalette() pluginview.Palette {
	t, k := a.theme, a.colors
	return pluginview.Palette{
		Dark: k.Dark, Text: k.Text, TextSecondary: t.MutedForeground, TextMuted: k.Subtle,
		Accent: k.Accent, Success: k.Success, Warning: k.Warning, Error: t.Danger,
		Surface: t.Card, Background: k.Ground, Sidebar: k.Chrome, Line: k.Line,
		Hover: k.Hover, Selection: k.Selection, Badge: t.Secondary,
		Popover: t.Popover, PopoverText: t.PopoverForeground,
	}
}

// endPluginViews runs at the end of each paint: a view of the open project that the paint did
// not declare closes, and every view is marked as not declared until the next paint declares it.
func (a *App) endPluginViews() {
	p := a.project
	if p == nil {
		return
	}
	for key, v := range p.pluginViews {
		if !v.shown {
			v.close()
			delete(p.pluginViews, key)
			continue
		}
		v.shown = false
	}
}

// closePluginViews closes every view of p, as the project closes.
func (a *App) closePluginViews(p *project) {
	for _, v := range p.pluginViews {
		v.close()
	}
	p.pluginViews = nil
}
