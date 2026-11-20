package workbench

import (
	"net"
	"os"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

func overrideRunPortTestHooks(t *testing.T, schedule []time.Duration) *[]string {
	t.Helper()
	prevSchedule := runPortSampleSchedule
	runPortSampleSchedule = slices.Clone(schedule)

	var opened []string
	prevOpen := openURL
	openURL = func(address string) error {
		opened = append(opened, address)
		return nil
	}

	t.Cleanup(func() {
		runPortSampleSchedule = prevSchedule
		openURL = prevOpen
	})
	return &opened
}

func TestRunWindowShowsLiveListeningPortAndOpensOrCopiesIt(t *testing.T) {
	opened := overrideRunPortTestHooks(t, []time.Duration{10 * time.Millisecond, 25 * time.Millisecond})

	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	defer listener.Close()

	label := ":" + strconv.Itoa(port)
	wantURL := "http://localhost:" + strconv.Itoa(port)

	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project

	var op *buildOperation
	h.app.post(func(a *App) {
		op = a.beginRunOperation(p, "WebService", "web", configurationRunKey("web"), nil)
		op.session.processRunning = true
		a.reduceChrome(core.SetChromeOpen(itemRun, true))
		a.startRunPortSampling(p, op.session, os.Getpid(), 0)
	})
	h.settle()
	t.Cleanup(func() {
		if op != nil && op.session != nil {
			h.app.post(func(*App) { stopRunPortSampling(op.session) })
		}
	})

	h.await("live listening port pill in Run window", func() bool {
		return h.shows(label) && h.shows(h.app.text.Run.Ports.Label)
	})

	// Left click opens the browser URL via openURL.
	h.clickNamed(wantURL)
	h.settle()
	if !slices.Contains(*opened, wantURL) {
		t.Fatalf("opened URLs = %v, want %q", *opened, wantURL)
	}

	// Right click opens context menu with Open and Copy; Copy puts the full URL on clipboard.
	h.driver.SetClipboard("")
	pill := h.pageHit(wantURL)
	if err := h.driver.ClickButton(center(pill.Bounds).X, center(pill.Bounds).Y, gfx.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.clickNamed(h.app.text.Run.Ports.Copy)
	h.settle()
	if got := h.driver.Clipboard(); got != wantURL {
		t.Fatalf("clipboard = %q, want %q", got, wantURL)
	}

	// Ending the run stops polling and removes active ports from the Run window.
	h.app.post(func(a *App) {
		a.endBuildOperation(p, op, "completed", nil, "", a.text.Run.Ended)
	})
	h.settle()
	if len(op.session.ports) != 0 || op.session.stopPorts != nil {
		t.Fatalf("finished run still holds ports=%+v stopPorts=%v", op.session.ports, op.session.stopPorts != nil)
	}
	if h.shows(h.app.text.Run.Ports.Label) {
		t.Fatal("listening ports label still shown after run ended")
	}
}

func TestRunPortSamplingExcludesDebugPort(t *testing.T) {
	overrideRunPortTestHooks(t, []time.Duration{10 * time.Millisecond, 25 * time.Millisecond})

	appLn, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer appLn.Close()
	appPort := appLn.Addr().(*net.TCPAddr).Port

	dbgLn, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dbgLn.Close()
	dbgPort := dbgLn.Addr().(*net.TCPAddr).Port

	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project

	appLabel := ":" + strconv.Itoa(appPort)
	dbgLabel := ":" + strconv.Itoa(dbgPort)

	var op *buildOperation
	h.app.post(func(a *App) {
		op = a.beginRunOperation(p, "WebService", "web", configurationRunKey("web"), nil)
		op.session.processRunning = true
		a.reduceChrome(core.SetChromeOpen(itemRun, true))
		a.startRunPortSampling(p, op.session, os.Getpid(), dbgPort)
	})
	h.settle()
	t.Cleanup(func() {
		if op != nil && op.session != nil {
			h.app.post(func(*App) { stopRunPortSampling(op.session) })
		}
	})

	h.await("app port to show while debug port stays excluded", func() bool {
		return h.shows(appLabel)
	})

	if h.shows(dbgLabel) {
		t.Fatalf("excluded debug port %s shown in Run window", dbgLabel)
	}
}
