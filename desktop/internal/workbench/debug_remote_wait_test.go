package workbench

import (
	"testing"
	"time"
)

// awaitRemotePrompt waits for the remote attach confirmation and, when it never appears, reports
// what the window knew: the adapter set, whether it loaded, the recorded failure and the pending
// start. The generic deadline message does not say which of those was wrong.
func awaitRemotePrompt(t *testing.T, h *harness, p *project) {
	t.Helper()
	deadline := time.NewTimer(20 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for p.debug.remote == nil {
		select {
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-tick.C:
		case <-deadline.C:
			t.Fatalf("the confirmation did not happen: adapters=%d loaded=%v selected=%d failure=%q pendingStart=%v sessions=%d documents=%d",
				len(p.debug.adapters), p.debug.loaded, p.debug.selectedAdapter, p.debug.failure,
				p.debug.pendingRemote != nil, len(p.debug.sessions), len(p.docs.list))
		}
	}
}

// awaitLinkedFile waits for the document a console link opens and reports the window's state when
// it never arrives: how many sources matched, which documents are open and whether the target is
// on disk.
func awaitLinkedFile(t *testing.T, h *harness, p *project, target string) *document {
	t.Helper()
	deadline := time.NewTimer(20 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		if d := p.docs.byPath(target); d != nil {
			return d
		}
		select {
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-tick.C:
		case <-deadline.C:
			opened := make([]string, 0, len(p.docs.list))
			for _, d := range p.docs.list {
				opened = append(opened, d.path)
			}
			t.Fatalf("the linked file to open did not happen: sources=%d documents=%v target=%q",
				len(p.links.sources), opened, target)
		}
	}
}
