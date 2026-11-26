//go:build vivahead && lithevisual

package pluginview

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/uistyle"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/headless"
	"github.com/vivaui/viva/ui"
)

// visualView is a tool window view that uses every host control and a canvas with clickable,
// selected and dashed shapes, as a module explorer plugin might draw it.
const visualView = `[
 {"type":"section","title":"Modules","info":"Modules the backend found in the workspace.","children":[
  {"type":"row","children":[
   {"type":"label","id":"count","text":"3 modules · 41 classes","style":"strong"},
   {"type":"button","id":"refresh","text":"Refresh","icon":"refresh"},
   {"type":"button","id":"build","text":"Build all","icon":"run","tone":"primary"}]},
  {"type":"segmented","id":"scope","label":"Scope","value":"all","options":[
   {"value":"all","label":"All modules"},{"value":"recent","label":"Recent"}]},
  {"type":"textField","id":"filter","placeholder":"Filter modules","width":"fill"},
  {"type":"tree","id":"modules","items":[
   {"id":"core","label":"core","icon":"plugin","detail":"18 classes","expanded":true,"children":[
    {"id":"core.api","label":"api","detail":"7 classes"},
    {"id":"core.impl","label":"impl","detail":"11 classes"}]},
   {"id":"app","label":"app","icon":"run","detail":"15 classes"},
   {"id":"tools","label":"tools","icon":"terminal","detail":"8 classes"}]},
  {"type":"toggle","id":"watch","label":"Rebuild on save","value":true}]},
 {"type":"section","title":"Last build","children":[
  {"type":"keyValue","items":[
   {"label":"Finished","value":"09:41"},
   {"label":"Duration","value":"12.4 s"},
   {"label":"Result","value":"Passed","tone":"success"}]},
  {"type":"banner","tone":"warning","text":"core.impl has 2 warnings."},
  {"type":"table","id":"slow","columns":[{"title":"Module"},{"title":"Time","align":"end"}],
   "rows":[["core","6.1 s"],["app","4.8 s"],["tools","1.5 s"]]}]},
 {"type":"canvas","id":"graph","label":"Module graph","height":170,"viewBox":[0,0,440,160],"nodes":[
  {"type":"rect","x":0,"y":0,"w":440,"h":160,"radius":8,"fill":"$surface","stroke":"$line"},
  {"type":"path","d":"M 140 75 L 180 75","stroke":"$accent","width":2},
  {"type":"path","d":"M 300 75 L 260 75","stroke":"$textMuted","width":1.5,"dash":[4,3]},
  {"type":"group","id":"node.app","x":20,"y":55,"w":120,"h":40,"radius":6,"on":["click"],"label":"app module",
   "states":{"hover":{"fill":"$hover"}},"children":[
   {"type":"rect","x":0,"y":0,"w":120,"h":40,"radius":6,"stroke":"$line"},
   {"type":"text","x":60,"y":25,"text":"app","style":"strong","align":"center"}]},
  {"type":"group","id":"node.core","x":180,"y":55,"w":80,"h":40,"radius":6,"on":["click"],"label":"core module","selected":true,
   "states":{"hover":{"fill":"$hover"},"selected":{"fill":"$selection","stroke":"$accent","width":1.5}},"children":[
   {"type":"text","x":40,"y":25,"text":"core","style":"strong","align":"center"}]},
  {"type":"group","id":"node.tools","x":300,"y":55,"w":120,"h":40,"radius":6,"on":["click"],"label":"tools module",
   "states":{"hover":{"fill":"$hover"}},"children":[
   {"type":"rect","x":0,"y":0,"w":120,"h":40,"radius":6,"stroke":"$line","dash":[4,3]},
   {"type":"text","x":60,"y":25,"text":"tools","style":"strong","align":"center"}]},
  {"type":"text","x":220,"y":140,"text":"2 edges · 1 optional","style":"caption","align":"center","color":"$textSecondary"}]}
]`

// visualPalette maps a Viva theme onto the view tokens as the workbench maps its own.
func visualPalette(theme gfx.Theme, dark bool) Palette {
	warning := gfx.RGBA(178, 107, 0, 1)
	if dark {
		warning = gfx.RGBA(229, 160, 58, 1)
	}
	return Palette{
		Dark: dark, Text: theme.Foreground, TextSecondary: theme.MutedForeground, TextMuted: theme.MutedForeground,
		Accent: theme.Primary, Success: theme.Success, Warning: warning, Error: theme.Danger,
		Surface: theme.Card, Background: theme.Background, Sidebar: theme.Muted, Line: theme.Border,
		Hover: theme.Hover, Selection: theme.Selection, Badge: theme.Secondary,
		Popover: theme.Popover, PopoverText: theme.PopoverForeground,
	}
}

// TestVisualPluginView renders a tool window view in the dark and the light theme. Opt in
// with -tags 'vivahead lithevisual' and LITHE_VISUAL_OUTPUT_DIR.
func TestVisualPluginView(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR to capture a plugin view")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, dark := range []bool{true, false} {
		name := "plugin-view-toolwindow-light"
		theme := ui.LightTheme()
		if dark {
			name, theme = "plugin-view-toolwindow-dark", ui.DarkTheme()
		}
		t.Run(name, func(t *testing.T) {
			b := newBackend(t)
			b.answer = func(map[string]any) (json.RawMessage, bool, error) { return json.RawMessage(visualView), true, nil }
			s := b.session()
			show(s)
			b.answered(s)
			if !s.Drawn() {
				t.Fatalf("the view was not drawn: %v", s.Err())
			}
			background := theme.Background
			invalidator := &app.Invalidator{}
			host := &Host{Palette: visualPalette(theme, dark), Language: i18n.English, Icon: HostIcon}
			page := ui.NewPage(ui.PageConfig{
				View: func(c ui.C) {
					ui.Column(c.Key("body")).Fill().Background(theme.Background).Children(func() { Draw(c, s, host, true) })
				},
				Theme: &theme, Background: &background, Invalidator: invalidator,
				// Every client window the view is drawn in turns these on.
				EllipsisTooltips: true,
			})
			session, err := headless.Open(ui.Configure(page, app.Config{Width: 480, Height: 860, Invalidator: invalidator}), nil, headless.Options{})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(session.Close)
			labels := map[string]bool{}
			for _, label := range session.Snapshot().Labels {
				labels[label.Value] = true
			}
			for _, text := range []string{"3 modules · 41 classes", "Rebuild on save", "core.impl has 2 warnings.", "2 edges · 1 optional"} {
				if !labels[text] {
					t.Errorf("the view does not show %q", text)
				}
			}
			if err := session.Screenshot(filepath.Join(out, name+".png")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// This synthetic view exercises the host canvas without installing a plugin.
func TestVisualCanvasEllipsis(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	const full = "完整文件名称-with-a-long-extension.txt · additional information"
	const view = `[{"type":"canvas","id":"graph","label":"Graph","height":180,"viewBox":[0,0,440,180],"nodes":[
		{"type":"group","id":"item","x":20,"y":20,"w":200,"h":80,"on":["click"],"label":"Open item","tooltip":"Group details","children":[
			{"type":"rect","x":0,"y":0,"w":200,"h":80,"radius":6,"fill":"$surface","stroke":"$line"},
			{"type":"text","x":10,"y":30,"maxWidth":110,"runs":[
				{"text":"完整文件名称-with-a-long-extension.txt"},{"text":" · additional information"}]}]}]}]`
	for _, language := range []i18n.Language{i18n.Chinese, i18n.English} {
		for _, dark := range []bool{true, false} {
			look := map[bool]string{true: "dark", false: "light"}[dark] + "-" + language.Code()
			t.Run(look, func(t *testing.T) {
				b := newBackend(t)
				b.answer = func(map[string]any) (json.RawMessage, bool, error) { return json.RawMessage(view), true, nil }
				s := b.session()
				show(s)
				b.answered(s)
				theme := ui.LightTheme()
				if dark {
					theme = ui.DarkTheme()
				}
				// Every client window sets this tip on its theme; the plugin view inherits it there.
				theme.Tooltip = uistyle.Tooltip(dark)
				background := theme.Background
				host := &Host{Palette: visualPalette(theme, dark), Language: language, Icon: HostIcon}
				page := ui.NewPage(ui.PageConfig{
					View: func(c ui.C) { Draw(c, s, host, true) }, Theme: &theme, Background: &background,
					// So does every client window, which shows the full text of the cut node.
					EllipsisTooltips: true,
				})
				session, err := headless.Open(ui.Configure(page, app.Config{Width: 480, Height: 300}), nil, headless.Options{})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(session.Close)
				shot := func(scene string) {
					t.Helper()
					if err := session.Screenshot(filepath.Join(out, "ellipsis-canvas-"+scene+"-"+look+".png")); err != nil {
						t.Fatal(err)
					}
				}
				shot("before-hover")
				found := false
				for _, label := range session.Snapshot().Labels {
					if strings.HasSuffix(label.Value, "…") {
						if err := session.Driver().Move(label.Bounds.X+5, label.Bounds.Y+label.Bounds.Height/2); err != nil {
							t.Fatal(err)
						}
						found = true
						break
					}
				}
				if !found {
					t.Fatal("the canvas did not shorten its label")
				}
				if err := session.Advance(time.Second); err != nil {
					t.Fatal(err)
				}
				var tip strings.Builder
				for _, label := range session.Snapshot().Labels {
					if label.Layer == ui.TooltipLayer {
						tip.WriteString(label.Value)
					}
				}
				if strings.Join(strings.Fields(tip.String()), "") != strings.Join(strings.Fields(full), "") {
					t.Fatalf("canvas tooltip %q, want %q", tip.String(), full)
				}
				shot("text-hover")
			})
		}
	}
}
