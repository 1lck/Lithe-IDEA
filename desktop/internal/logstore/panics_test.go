package logstore

import (
	"context"
	"encoding/json"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const panicEvent = "app.runtime.panic_interrupted"

//go:noinline
func panicFixture() {
	panic("fixture")
}

// recoveredStack recovers panicFixture's panic the way a boundary does and returns the stack
// debug.Stack prints there.
func recoveredStack() (stack []byte) {
	defer func() {
		if recover() != nil {
			stack = debug.Stack()
		}
	}()
	panicFixture()
	return nil
}

// panicRecords lists the written app.runtime.panic_interrupted records of the current session.
func panicRecords(t *testing.T, s *Store) []core.LogRecord {
	t.Helper()
	var records []core.LogRecord
	for _, record := range window(t, s, Query{Session: "current"}).Records {
		if record.Event == panicEvent {
			records = append(records, record)
		}
	}
	return records
}

func TestRecoveredPanicReachesTheDisk(t *testing.T) {
	s, _, _ := openStore(t, nil)
	flush(t, s)

	// Nothing but RecordPanic schedules the drain that writes it.
	written := awaitLine(t, s, panicEvent)
	s.RecordPanic("viva:darwin: AppKit callback", "index out of range\n[3] with length 2", recoveredStack())
	written()

	records := panicRecords(t, s)
	if len(records) != 1 {
		t.Fatalf("panic records = %+v, want one", records)
	}
	fields := records[0].Fields
	if fields["boundary"] != "viva:darwin:appkit-callback" || fields["panic"] != "index out of range [3] with length 2" {
		t.Fatalf("panic fields = %+v", fields)
	}
	if !strings.HasPrefix(fields["stack"], "logstore.panicFixture panics_test.go:") {
		t.Fatalf("panic stack = %q, want it to start at the panicking frame", fields["stack"])
	}
}

func TestPanicRecordedWhileClosingIsWritten(t *testing.T) {
	s, _, dir := openStore(t, nil)
	flush(t, s)

	// Close has begun: the store takes no more events, but the panic that ends the
	// application still reaches the final drain.
	s.mu.Lock()
	s.stopped = true
	s.mu.Unlock()
	action(s, "after_close_began")
	s.RecordPanic("viva:window procedure", "", nil)
	s.Close()

	text := readTree(t, dir)
	if !strings.Contains(text, panicEvent) || !strings.Contains(text, "viva:window-procedure") || !strings.Contains(text, "<empty>") {
		t.Fatalf("the panic recorded while closing is missing from the log:\n%s", text)
	}
	if strings.Contains(text, "after_close_began") {
		t.Fatal("an ordinary event queued after Close began was written")
	}
}

func TestPanicQueueKeepsTheOldestWithinItsLimit(t *testing.T) {
	clock := newTestClock()
	q := panicQueue{now: clock.Now}
	for i := range panicLimit + 12 {
		q.Emit(core.LevelError, panicEvent, "", map[string]any{"panic": strconv.Itoa(i)})
	}
	events, lost := q.take()
	if len(events) != panicLimit || lost != 12 {
		t.Fatalf("took %d events, %d lost; want %d and 12", len(events), lost, panicLimit)
	}
	for i, event := range events {
		if event.fields["panic"] != strconv.Itoa(i) || (i > 0 && !events[i-1].ts.Before(event.ts)) {
			t.Fatalf("event %d = %+v, want the queue's order", i, event)
		}
	}
	// Taking frees the room and resets the loss.
	q.Emit(core.LevelError, panicEvent, "", nil)
	if events, lost := q.take(); len(events) != 1 || lost != 0 {
		t.Fatalf("after taking: %d events, %d lost; want 1 and 0", len(events), lost)
	}
}

func TestLostPanicsAreReportedAsDropped(t *testing.T) {
	s, _, _ := openStore(t, nil)
	flush(t, s)

	s.panics.lost.Add(3)
	flush(t, s)
	if dropped, _ := s.Stats(); dropped != 3 {
		t.Fatalf("dropped = %d, want the 3 lost panics", dropped)
	}
	counts := fieldValues(window(t, s, Query{Session: "current"}).Records, droppedEvent, "count")
	if len(counts) != 1 || counts[0] != "3" {
		t.Fatalf("log.dropped counts = %v, want [3]", counts)
	}
}

func TestPanicsAndEventsRecordedTogether(t *testing.T) {
	s, _, _ := openStore(t, nil)
	flush(t, s)

	const workers, each = 4, 10
	var wg sync.WaitGroup
	for w := range workers {
		wg.Go(func() {
			for i := range each {
				s.RecordPanic("viva:shortcut hook", "worker "+strconv.Itoa(w)+" panic "+strconv.Itoa(i), nil)
				action(s, "worker_"+strconv.Itoa(w)+"_"+strconv.Itoa(i))
			}
		})
	}
	wg.Wait()
	flush(t, s)

	// Every panic is either written or counted; the ordinary events all arrive.
	records := window(t, s, Query{Session: "current"}).Records
	dropped, failures := s.Stats()
	if got := eventCounts(records); got[panicEvent]+dropped != workers*each || got["app.action.performed"] != workers*each || failures != 0 {
		t.Fatalf("written %v, dropped %d, failures %d; want %d panics written or dropped", got, dropped, failures, workers*each)
	}
}

func TestKernelPanicsReachTheStore(t *testing.T) {
	kernel := &wakingKernel{Kernel: core.NewClient()}
	s, _, _ := openStore(t, func(o *Options) { o.Kernel = kernel })
	s.ObserveCoreFacts()
	flush(t, s)

	written := awaitLine(t, s, "core:events-observer")
	kernel.reportPanic(core.RecoveredPanic{Boundary: "core:events-observer", Value: "observer broke", Stack: recoveredStack()})
	written()

	s.Close()
	// After Close the store no longer receives the kernel's panics.
	kernel.reportPanic(core.RecoveredPanic{Boundary: "core:log-waker", Value: "late"})
	if events, _ := s.panics.take(); len(events) != 0 {
		t.Fatalf("a closed store received %d kernel panics", len(events))
	}
}

func TestObserverPanicOfARealRequestIsWritten(t *testing.T) {
	s, _, _ := openStore(t, nil)
	s.ObserveCoreFacts()
	flush(t, s)

	written := awaitLine(t, s, "core:events-observer")
	ctx, cancel := context.WithTimeout(context.Background(), waitLimit)
	defer cancel()
	var result json.RawMessage
	observationErr, requestErr := s.kernel.(*core.Client).ExecuteWithEvents(ctx, "core.ping", nil, &result, func(json.RawMessage) {
		panic("observer broke")
	})
	if requestErr != nil || observationErr == nil {
		t.Fatalf("ExecuteWithEvents = %v, %v; want the observation lost and the request answered", observationErr, requestErr)
	}
	written()
	records := panicRecords(t, s)
	if len(records) != 1 || records[0].Fields["panic"] != "observer broke" ||
		!strings.Contains(records[0].Fields["stack"], "panics_test.go:") {
		t.Fatalf("panic records = %+v", records)
	}
}
