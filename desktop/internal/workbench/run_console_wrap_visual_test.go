//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// wrapOutput is a build's output with lines far wider than the console, some of them in the
// colors the build printed them in.
const wrapOutput = "make -C build all\n" +
	"cc -O2 -Wall -Wextra -Werror -std=c17 -I./include -I./third_party/zlib -I./third_party/yaml/include -DNDEBUG -DAPP_VERSION=\\\"1.4.2\\\" -c src/compress/deflate_stream_encoder.c -o build/obj/compress/deflate_stream_encoder.o\n" +
	"\x1b[1;33mwarning:\x1b[0m src/compress/deflate_stream_encoder.c:218:17: implicit conversion loses integer precision: 'size_t' (aka 'unsigned long') to 'int' when the window is resized while a block is still being written [-Wshorten-64-to-32]\n" +
	"cc -O2 -Wall -Wextra -Werror -std=c17 -I./include -I./third_party/zlib -I./third_party/yaml/include -DNDEBUG -c src/config/loader.c -o build/obj/config/loader.o\n" +
	"\x1b[32mok\x1b[0m   build/bin/app linked from 42 objects in 1.8s; see https://example.test/builds/2026-11-18/app/linking-report.html for the full report\n"

// TestVisualRunConsoleWrap captures the Run console holding a build's long lines, with the wrap
// switch in its toolbar off, where a line ends in an ellipsis at the console's edge, and on,
// where it breaks onto more rows in the colors it was printed in.
func TestVisualRunConsoleWrap(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		t.Run(look.theme, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 760
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(t.TempDir())
			p := h.app.project
			run := &runEntry{id: "run-1", label: "Makefile", output: newOutputBuffer(runOutputMaxLines, runOutputBytes)}
			chunk, err := newOutputDecoder(h.app.kernel, h.app.outputEncodingPolicy()).decode(wrapOutput)
			if err != nil {
				t.Fatal(err)
			}
			run.output.apply(chunk)
			p.build.runs = append(p.build.runs, run)
			p.build.view = run.id
			if !h.app.chrome.isOpen(catalogIndex[itemRun]) {
				h.app.reduceChrome(core.SetChromeOpen(itemRun, true))
			}
			capture := func(id string) {
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, id+"-"+look.theme+".png")); err != nil {
					t.Fatal(err)
				}
			}
			capture("run-console-cut")
			h.clickNamed(i18n.Shared(h.app.language(), "git.console.wrap"))
			if !h.app.runWrap {
				t.Fatal("a click on the wrap switch did not turn it on")
			}
			capture("run-console-wrapped")
			for _, sample := range []pluginservice.ProcessSample{
				{CPUPercent: 12, MemoryBytes: 64 << 20},
				{CPUPercent: 42, MemoryBytes: 76 << 20},
				{CPUPercent: 34, MemoryBytes: 84 << 20},
				{CPUPercent: 58, MemoryBytes: 108 << 20},
				{CPUPercent: 25, MemoryBytes: 96 << 20},
			} {
				run.addSample(sample)
			}
			h.app.invalidator.Invalidate()
			capture("run-performance-expanded")
			h.clickNamed(i18n.Shared(h.app.language(), "native.collapseSection"))
			if !h.app.settings.RunPerformanceCollapsed {
				t.Fatal("the graph did not collapse")
			}
			capture("run-performance-collapsed")
		})
	}
}
