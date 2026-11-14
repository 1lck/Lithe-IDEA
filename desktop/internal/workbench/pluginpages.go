package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginweb"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// A web tool window (`ui` 2) shows a page of its plugin's package in a web view of the
// system's engine. Core decides what the page is served and which bridge requests it may
// make; pluginweb does the I/O, and this file owns the views.
//
// A page lives while its window is shown in the open project: a paint that no longer
// declares it closes it, so hiding or moving the window, closing the project, and
// disabling, updating or uninstalling the plugin all end it, and its calls are
// cancelled. The contract lets a host do that; a page restores itself from the state it
// keeps through the bridge, which is stored with the plugin's state, outside its package
// and the application bundle.
//
// Note: the decision is recorded in
// .agents/notes/implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md

// pluginPage is the page of one web tool window.
type pluginPage struct {
	tool    pluginservice.ToolWindow
	project *project
	page    *pluginweb.Page
	view    *app.WebView
	// failure is why the page could not open; the window says so instead.
	failure string
	// shown is set by each paint that declares the window.
	shown bool
	// colors is the palette the page was last given.
	colors palette
}

func (page *pluginPage) close() {
	if page.page != nil {
		page.page.Close()
	} else if page.view != nil {
		page.view.Close()
	}
}

// pluginWebBody declares a web tool window: the page, or why it cannot be shown.
func (a *App) pluginWebBody(c ui.C, it item, p *project) {
	page := a.pluginPage(it, p)
	if page == nil {
		a.pluginPageMessage(c, i18n.Shared(a.language(), "desktop.pluginWeb.loading"))
		return
	}
	page.shown = true
	if page.view == nil {
		a.pluginPageMessage(c, i18n.SharedFormat(a.language(), "desktop.pluginWeb.unavailable", map[string]string{"reason": page.failure}))
		return
	}
	if page.colors != a.colors {
		page.colors = a.colors
		page.page.SetTheme(a.pluginPageTheme())
	}
	ui.Slot(c).Fill().NativeView(page.view.ID())
}

func (a *App) pluginPageMessage(c ui.C, message string) {
	ui.Row(c).Fill().Items(ui.Center).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, message, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
	})
}

// pluginPage returns the page of a web tool window in project p, opening it on first
// use. It is nil while the window's web host is not ready yet.
func (a *App) pluginPage(it item, p *project) *pluginPage {
	if page := a.pluginPages[it.id]; page != nil && page.project == p {
		return page
	}
	if !a.webReady {
		return nil
	}
	page := &pluginPage{tool: *it.tool, project: p, colors: a.colors}
	if a.pluginPages == nil {
		a.pluginPages = make(map[string]*pluginPage)
	}
	a.pluginPages[it.id] = page
	if err := a.openPluginPage(page); err != nil {
		page.failure = err.Error()
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_web_open", err))
	}
	return page
}

func (a *App) openPluginPage(page *pluginPage) error {
	kernel, ok := a.kernel.(pluginweb.Kernel)
	if !ok || a.plugins == nil {
		return errors.ErrUnsupported
	}
	host := &pluginPageHost{a: a, plugins: a.plugins, tool: page.tool, project: page.project, language: a.language()}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	opened, err := pluginweb.Open(ctx, pluginweb.Config{
		Kernel:  kernel,
		Host:    host,
		Package: page.tool.Package,
		Open: core.PluginWebOpen{
			Manifest: page.tool.Manifest, WindowID: page.tool.ID, Platform: buildPlatform(),
			Locale: pluginPageLocale(a.language()), Theme: a.pluginPageTheme(),
		},
		Post: func(fn func()) { a.post(func(*App) { fn() }) },
		Log: func(stage string, err error) {
			a.post(func(a *App) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_web_"+stage, err))
			})
		},
	})
	if err != nil {
		return err
	}
	host.stateLimit = opened.Info().StateLimit
	info := opened.Info()
	view, err := a.web.Open(app.WebViewConfig{
		URL:       info.URL,
		Scheme:    &app.WebScheme{Name: info.Scheme, Serve: opened.Serve},
		OnMessage: opened.Receive,
		OnLoad: func(load app.WebLoad) {
			if load.Phase == app.WebLoadCommitted {
				opened.Loaded(load.URL)
			}
		},
	})
	if err != nil {
		opened.Close()
		return err
	}
	opened.Attach(view)
	page.page, page.view = opened, view
	return nil
}

// endPluginPageFrame closes the pages the paint did not declare.
func (a *App) endPluginPageFrame() {
	for id, page := range a.pluginPages {
		if !page.shown {
			page.close()
			delete(a.pluginPages, id)
			continue
		}
		page.shown = false
	}
}

// closePluginPages closes every page, for a project that closes.
func (a *App) closePluginPages() {
	for id, page := range a.pluginPages {
		page.close()
		delete(a.pluginPages, id)
	}
}

// closeStalePluginPages closes the pages whose window is gone from the catalog or now
// comes from another package.
func (a *App) closeStalePluginPages() {
	for id, page := range a.pluginPages {
		index, known := a.chrome.index[id]
		if !known || a.chrome.catalog[index].tool == nil || !sameToolWindow(a.chrome.catalog[index].tool, &page.tool) {
			page.close()
			delete(a.pluginPages, id)
		}
	}
}

// pluginPageLocale is the locale a page is told, in the contract's terms.
func pluginPageLocale(language i18n.Language) string {
	if language == i18n.Chinese {
		return "zh-CN"
	}
	return "en"
}

// pluginPageTheme is the window's look in the --lithe-* variables pages style
// themselves with, the names the macOS client gave them. Over a workbench background
// image the panel and editor colors are clear so the image shows through a page; a
// popup floats over the page's own content, so it gets the ground, which stays opaque.
func (a *App) pluginPageTheme() core.PluginWebTheme {
	c := a.colors
	theme := "light"
	if c.Dark {
		theme = "dark"
	}
	return core.PluginWebTheme{Theme: theme, Variables: map[string]string{
		"--lithe-background":           cssColor(c.Panel),
		"--lithe-surface":              cssColor(c.Editor),
		"--lithe-header":               cssColor(c.Panel),
		"--lithe-popup-background":     cssColor(c.Ground),
		"--lithe-foreground":           cssColor(c.Text),
		"--lithe-secondary-foreground": cssColor(c.Subtle),
		"--lithe-border":               cssColor(c.Line),
		"--lithe-accent":               cssColor(c.Accent),
		"--lithe-link":                 cssColor(c.Accent),
		"--lithe-success":              cssColor(c.Success),
		"--lithe-warning":              cssColor(c.Warning),
		"--lithe-error":                cssColor(c.Deleted),
		"--lithe-font-family":          `"Inter", -apple-system, system-ui, sans-serif`,
		"--lithe-font-size":            "13px",
		"--lithe-code-font-family":     `ui-monospace, "JetBrains Mono", Menlo, Consolas, monospace`,
		"--lithe-code-font-size":       "13px",
	}}
}

// cssColor writes a color as CSS rgba().
func cssColor(c gfx.Color) string {
	channel := func(v float32) int { return int(min(max(v, 0), 1)*255 + 0.5) }
	return fmt.Sprintf("rgba(%d, %d, %d, %.3g)", channel(c.Red), channel(c.Green), channel(c.Blue), min(max(c.Alpha, 0), 1))
}

// pluginPageHost carries out the checked requests of one page for the project it is
// shown in.
type pluginPageHost struct {
	a          *App
	plugins    *pluginservice.Service
	tool       pluginservice.ToolWindow
	project    *project
	language   i18n.Language
	stateLimit int
}

func (h *pluginPageHost) State(_ context.Context, pluginID, windowID string) ([]byte, error) {
	return h.plugins.PageState(pluginID, windowID, h.project.root, h.stateLimit)
}

func (h *pluginPageHost) SetState(_ context.Context, pluginID, windowID string, state []byte) error {
	return h.plugins.SetPageState(pluginID, windowID, h.project.root, state, h.stateLimit)
}

func (h *pluginPageHost) BackendFunctions(ctx context.Context, pluginID string) ([]string, error) {
	return h.plugins.Host.Functions(ctx, pluginID)
}

func (h *pluginPageHost) CallBackend(ctx context.Context, pluginID, function string, params json.RawMessage, progress func(json.RawMessage)) (json.RawMessage, error) {
	return h.plugins.CallFromPage(ctx, pluginID, function, params, h.project.root, progress)
}

// ChooseFile shows the system's file dialog, titled with the plugin's name so the user
// knows who asks.
func (h *pluginPageHost) ChooseFile(_ string, request pluginweb.FileRequest) (string, error) {
	name := h.tool.PluginName
	if name == "" {
		name = h.tool.PluginID
	}
	title := i18n.SharedFormat(h.language, "desktop.pluginWeb.openFileTitle", map[string]string{"plugin": name})
	if request.Save {
		title = i18n.SharedFormat(h.language, "desktop.pluginWeb.saveFileTitle", map[string]string{"plugin": name})
	}
	if request.Title != "" {
		title = i18n.SharedFormat(h.language, "desktop.pluginWeb.dialogTitle", map[string]string{"plugin": name, "title": request.Title})
	}
	var filters []app.FileFilter
	if len(request.Extensions) > 0 {
		patterns := make([]string, len(request.Extensions))
		for i, extension := range request.Extensions {
			patterns[i] = "*." + extension
		}
		filters = []app.FileFilter{{
			Name:    i18n.SharedFormat(h.language, "desktop.pluginWeb.fileFilter", map[string]string{"extensions": strings.Join(request.Extensions, ", ")}),
			Pattern: strings.Join(patterns, ";"),
		}}
	}
	var path string
	var err error
	if request.Save {
		path, err = app.SaveFile(app.SaveFileOptions{Title: title, SuggestedName: request.SuggestedName, Filters: filters})
	} else {
		var paths []string
		paths, err = app.OpenFiles(app.OpenFileOptions{Title: title, Filters: filters})
		if len(paths) > 0 {
			path = paths[0]
		}
	}
	if errors.Is(err, app.ErrCanceled) {
		return "", nil
	}
	return path, err
}

// OpenFile opens a file of the workspace in the editor. Core refused paths with "..";
// a path that leads out of the workspace through a link is refused here.
func (h *pluginPageHost) OpenFile(path string, line, column int) error {
	a, p := h.a, h.project
	if a.project != p {
		return pluginweb.Fail("plugin.web.forbidden", "The workspace of this page is closed.")
	}
	target := path
	if !filepath.IsAbs(target) {
		target = filepath.Join(p.root, target)
	}
	resolved, err := filepath.EvalSymlinks(target)
	if err != nil {
		return pluginweb.Fail("plugin.web.invalidRequest", path+" does not exist.")
	}
	root, err := filepath.EvalSymlinks(p.root)
	if err != nil {
		return err
	}
	if relative, err := filepath.Rel(root, resolved); err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return pluginweb.Fail("plugin.web.forbidden", path+" is outside the workspace.")
	}
	if info, err := os.Stat(resolved); err != nil || !info.Mode().IsRegular() {
		return pluginweb.Fail("plugin.web.invalidRequest", path+" is not a file.")
	}
	if line <= 0 {
		a.openFileAt(p, target, 0)
		return nil
	}
	a.openFileAtPosition(p, target, line-1, max(column-1, 0))
	return nil
}
