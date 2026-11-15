package workbench

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/vivaui/viva/app"
)

// The window finds the log that records Viva's recovered panics by a type assertion on its log
// sink, which would silently leave them unlogged if the store stopped implementing it.
var _ panicSink = (*logstore.Store)(nil)

type recordedPanic struct {
	boundary, value string
	stack           []byte
}

type recordedEvent struct {
	event, op string
	fields    map[string]any
}

// faultLog is a log sink that keeps the panics and events it is given.
type faultLog struct {
	opRecordingLog
	mu     sync.Mutex
	panics []recordedPanic
	events []recordedEvent
}

func (l *faultLog) RecordPanic(boundary, value string, stack []byte) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.panics = append(l.panics, recordedPanic{boundary: boundary, value: value, stack: stack})
}

func (l *faultLog) Emit(level core.LogLevel, event, op string, fields map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, recordedEvent{event: event, op: op, fields: fields})
}

// TestVivaFaultsAreRecordedAsPanics checks that the fault handler the window installs records
// each panic Viva recovers under the boundary viva:<where>, with its message and stack, and
// marks the window loop as faulted, and that a window without a log that records panics
// installs none.
func TestVivaFaultsAreRecordedAsPanics(t *testing.T) {
	log := &faultLog{}
	a := &App{logSink: log}
	faulted := new(atomic.Bool)
	record := a.faultRecorder(faulted)
	if record == nil {
		t.Fatal("no fault handler for a log that records panics")
	}
	stack := []byte("goroutine 1 [running]:\n")
	record(app.Fault{Where: "darwin: AppKit callback", Message: "boom", Stack: stack})
	if len(log.panics) != 1 || log.panics[0].boundary != "viva:darwin: AppKit callback" ||
		log.panics[0].value != "boom" || string(log.panics[0].stack) != string(stack) {
		t.Fatalf("recorded panics = %+v", log.panics)
	}
	if !faulted.Load() {
		t.Fatal("the window loop is not marked as faulted")
	}

	plain := &App{logSink: &opRecordingLog{}}
	if plain.faultRecorder(new(atomic.Bool)) != nil {
		t.Fatal("a fault handler for a log that cannot record panics")
	}
	if (&App{}).faultRecorder(new(atomic.Bool)) != nil {
		t.Fatal("a fault handler without a log")
	}
}

// TestAFailedWindowLoopIsLogged checks that an error the window loop ends with is logged as
// app.window.loop_failed under no action, unless a recovered panic caused it, and that a loop
// that ends cleanly logs nothing.
func TestAFailedWindowLoopIsLogged(t *testing.T) {
	log := &faultLog{}
	a := &App{logSink: log}
	a.windowLoopEnded(nil, false)
	a.windowLoopEnded(errors.New("panic in AppKit callback"), true)
	if len(log.events) != 0 {
		t.Fatalf("events = %+v, want none for a clean end or a panic already recorded", log.events)
	}
	a.windowLoopEnded(errors.New("window: create failed"), false)
	if len(log.events) != 1 || log.events[0].event != "app.window.loop_failed" || log.events[0].op != "" ||
		log.events[0].fields["error_code"] == "" || log.events[0].fields["error"] == nil {
		t.Fatalf("events = %+v, want one app.window.loop_failed with the error", log.events)
	}
	(&App{}).windowLoopEnded(errors.New("no log"), false)
}
