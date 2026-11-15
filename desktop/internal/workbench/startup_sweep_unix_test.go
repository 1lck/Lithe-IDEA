//go:build !windows

package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
)

// unplannedKernel is the real kernel except that it cannot plan process lifecycles.
type unplannedKernel struct{ *core.Client }

func (unplannedKernel) ResolveProcessLifecycle(context.Context, string, json.RawMessage, []core.ProcessRecord) (core.ProcessPlan, error) {
	return core.ProcessPlan{}, errors.New("no plan")
}

// leftoverProcess is a process an earlier run of the app left behind: a sleep recorded in the
// preferences' ledger under kind. ended closes once it exited and was reaped.
type leftoverProcess struct {
	cmd   *exec.Cmd
	ended chan struct{}
}

// startLeftoverProcess starts a sleep and records it as kind in the ledger in h's preferences.
// It is killed when the test ends.
func startLeftoverProcess(t *testing.T, h *harness, kind string) *leftoverProcess {
	t.Helper()
	cmd := exec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	process := &leftoverProcess{cmd: cmd, ended: make(chan struct{})}
	go func() {
		_ = cmd.Wait()
		close(process.ended)
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-process.ended
	})
	if err := processledger.Open(h.store.Dir()).AddKind(kind, cmd.Process.Pid); err != nil {
		t.Fatal(err)
	}
	return process
}

// running reports that the process is still running after a short look.
func (p *leftoverProcess) running() bool {
	select {
	case <-p.ended:
		return false
	case <-time.After(200 * time.Millisecond):
		return true
	}
}

// endedWithin reports that the process ended within limit.
func (p *leftoverProcess) endedWithin(limit time.Duration) bool {
	select {
	case <-p.ended:
		return true
	case <-time.After(limit):
		return false
	}
}

// openLeftoverService assembles the plugin stack the way a first window does, which finds the
// leftovers in the ledger.
func openLeftoverService(t *testing.T, h *harness) {
	t.Helper()
	service, err := pluginservice.Open(core.NewClient(), h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	if leftovers := service.StartupLeftovers(); len(leftovers) != 2 {
		t.Fatalf("the service found %+v", leftovers)
	}
}

// recordedLeftovers is what the ledger in h's preferences still holds.
func recordedLeftovers(t *testing.T, h *harness) []processledger.Record {
	t.Helper()
	records, err := processledger.Open(h.store.Dir()).Leftovers()
	if err != nil {
		t.Fatal(err)
	}
	return records
}

// awaitLeftoversSettled pumps the window until the ledger holds no leftover. A settlement
// writes the ledger before it posts its result, so the post's wake sees the write.
func awaitLeftoversSettled(t *testing.T, h *harness) {
	t.Helper()
	awaitStateWithin(t, h, 20*time.Second, "the leftovers to settle", func() bool { return len(recordedLeftovers(t, h)) == 0 })
}

// TestStartupSweepEndsWhatCoreEndsAndAsksAboutTerminals: with the default settings Core ends a
// leftover build without asking and asks about a leftover terminal; ending the terminal on the
// answer leaves nothing recorded.
func TestStartupSweepEndsWhatCoreEndsAndAsksAboutTerminals(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	build := startLeftoverProcess(t, h, processledger.KindBuild)
	terminal := startLeftoverProcess(t, h, processledger.KindTerminal)
	openLeftoverService(t, h)

	h.app.planStartupSweep()
	awaitStateWithin(t, h, 20*time.Second, "the start-up question", func() bool { return h.app.startupSweep.open })
	question := h.app.startupSweep
	if len(question.leftovers) != 1 || question.leftovers[0].PID != terminal.cmd.Process.Pid || len(question.decisions) != 1 || question.decisions[0].Action != "ask" {
		t.Fatalf("the question is %+v, want only the terminal", question)
	}
	if question.grace <= 0 {
		t.Fatalf("the plan gave no stop time: %+v", question)
	}
	if !build.endedWithin(10 * time.Second) {
		t.Fatal("Core's plan ends the build, but it still runs")
	}
	if !terminal.running() {
		t.Fatal("the terminal ended before the user answered")
	}

	h.app.settleStartupSweep(true)
	if h.app.startupSweep.open {
		t.Fatal("the question stayed open after the answer")
	}
	awaitLeftoversSettled(t, h)
	if !terminal.endedWithin(10 * time.Second) {
		t.Fatal("the answer ends the terminal, but it still runs")
	}
}

// TestStartupSweepEndsTerminalsWhenTheSettingSaysSo: the startup sweep setting ends a leftover
// terminal without a question.
func TestStartupSweepEndsTerminalsWhenTheSettingSaysSo(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.settings.ProcessTermination.StartupSweep = "terminate"
	build := startLeftoverProcess(t, h, processledger.KindBuild)
	terminal := startLeftoverProcess(t, h, processledger.KindTerminal)
	openLeftoverService(t, h)

	h.app.planStartupSweep()
	awaitLeftoversSettled(t, h)
	if !build.endedWithin(10*time.Second) || !terminal.endedWithin(10*time.Second) {
		t.Fatal("the plan ends both leftovers, but one still runs")
	}
	if h.app.startupSweep.open {
		t.Fatalf("the setting ends terminals, but the question opened: %+v", h.app.startupSweep)
	}
}

// TestStartupSweepAsksAboutEverythingWithoutAPlan: when Core cannot plan, every leftover is asked
// about and none is ended; keeping them forgets them and leaves them running.
func TestStartupSweepAsksAboutEverythingWithoutAPlan(t *testing.T) {
	h := newHarness(t, unplannedKernel{Client: core.NewClient()})
	build := startLeftoverProcess(t, h, processledger.KindBuild)
	terminal := startLeftoverProcess(t, h, processledger.KindTerminal)
	openLeftoverService(t, h)

	h.app.planStartupSweep()
	awaitStateWithin(t, h, 20*time.Second, "the start-up question", func() bool { return h.app.startupSweep.open })
	if question := h.app.startupSweep; len(question.leftovers) != 2 || question.decisions != nil {
		t.Fatalf("the question is %+v, want both leftovers without decisions", question)
	}
	if !build.running() || !terminal.running() {
		t.Fatal("a leftover ended without a plan or an answer")
	}

	h.app.settleStartupSweep(false)
	awaitLeftoversSettled(t, h)
	if !build.running() || !terminal.running() {
		t.Fatal("a kept leftover was ended")
	}
}
