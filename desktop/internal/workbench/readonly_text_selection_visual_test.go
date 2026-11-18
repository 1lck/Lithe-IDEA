//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
	"github.com/vivaui/viva/ui/textview"
)

// TestVisualReadOnlyTextSelection captures the read-only text the user selects and copies
// (#2073, #2082), each with a selection across its lines: the Run console holding a stack
// trace, the details of a commit in the Git log, and the Git console holding a fetch with a
// closed fold, its toggle at the right edge.
func TestVisualReadOnlyTextSelection(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		// open makes a window of the look over kernel, and the session that captures it.
		open := func(t *testing.T, kernel Kernel) (*harness, *headless.Session) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: kernel, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1200, 760
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			return h, session
		}
		capture := func(t *testing.T, h *harness, session *headless.Session, id string) {
			h.settleChain()
			if err := session.Screenshot(filepath.Join(out, id+"-"+look.theme+".png")); err != nil {
				t.Fatal(err)
			}
		}

		t.Run("run-console-"+look.theme, func(t *testing.T) {
			h, session := open(t, &testKernel{Client: core.NewClient()})
			h.open(t.TempDir())
			p := h.app.project
			run := &runEntry{id: "run-1", label: "Main", output: newOutputBuffer(runOutputMaxLines, runOutputBytes)}
			chunk, err := newOutputDecoder(h.app.kernel).decode(stackTrace)
			if err != nil {
				t.Fatal(err)
			}
			run.output.apply(chunk)
			p.build.runs = append(p.build.runs, run)
			p.build.view = run.id
			if !h.app.chrome.isOpen(catalogIndex[itemRun]) {
				h.app.reduceChrome(core.SetChromeOpen(itemRun, true))
			}
			h.settle()
			h.drag(consolePoint(t, run, 0, len("Exception in thread \"main\" ")), consolePoint(t, run, 2, len("\tat demo.Main.main")))
			capture(t, h, session, "run-console-selection")
		})

		t.Run("git-log-details-"+look.theme, func(t *testing.T) {
			h, session := open(t, gitKernel{core.NewClient()})
			dir := newTestRepository(t)
			gitRun(t, dir, "commit", "--allow-empty", "-m", "fix: copy the details\n\nfirst body line\nsecond body line")
			head := gitRun(t, dir, "rev-parse", "HEAD")
			h.app.delays = logDelays{}
			h.open(dir)
			h.app.reduceChrome(core.SetChromeOpen(itemGit, true))
			h.settleChain()
			p := h.app.project
			if p == nil || !p.git.isRepository() {
				t.Fatalf("the project is not a loaded repository: %+v", p)
			}
			v := &h.app.logView
			v.filesSplit.Pos = logFilesMin
			h.app.layout.bottom = 10000
			h.app.layout.gitTab = gitTabLog
			h.settle()
			if !p.log.started {
				h.click(center(h.button(itemGit)))
				h.settle()
			}
			h.app.selectCommit(p, head)
			h.settle()
			h.settle()
			if p.log.detail == nil {
				t.Fatalf("no details of %q", head)
			}
			from, ok := v.detailText.PointOf(textview.Point{Line: 1, Byte: 0})
			to, ok2 := v.detailText.PointOf(textview.Point{Line: 3, Byte: len("first body")})
			if !ok || !ok2 {
				t.Fatal("the details are not on screen")
			}
			h.drag(from, to)
			capture(t, h, session, "git-log-details-selection")
		})

		t.Run("git-console-"+look.theme, func(t *testing.T) {
			h, session := open(t, gitKernel{core.NewClient()})
			h.openConsole(t, newTestRepository(t))
			v := &h.app.consoleView
			record, presented := consoleFetch()
			presented.search, presented.display = v.searchFor, v.display
			v.snapshot.Records = []core.GitConsoleRecord{record}
			v.presented[record.ID] = presented
			v.dirty = true
			h.app.invalidator.Invalidate()
			h.settle()
			h.drag(gitConsolePoint(t, v, 0, 0), gitConsolePoint(t, v, 2, len("Receiving")))
			capture(t, h, session, "git-console-selection")
		})
	}
}
