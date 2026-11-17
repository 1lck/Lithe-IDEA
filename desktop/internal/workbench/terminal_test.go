package workbench

import (
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
)

// levelLog records the level, event and fields of each event the window logs.
type levelLog struct {
	opRecordingLog
	events []leveledEvent
}

type leveledEvent struct {
	level  core.LogLevel
	event  string
	fields map[string]any
}

func (l *levelLog) Emit(level core.LogLevel, event, op string, fields map[string]any) {
	l.events = append(l.events, leveledEvent{level: level, event: event, fields: fields})
}

// A terminal failure is logged with the fields its event has: a shell that started on a
// fallback carries its operation, a failed start its stage.
func TestTerminalFailuresAreLoggedWithTheirEventsFields(t *testing.T) {
	log := &levelLog{}
	a := &App{logSink: log}
	reason := errors.New("conpty: install conpty.dll: access denied")
	a.terminalFailed(termview.Failure{Event: backgroundFailedEvent, Operation: "terminal_conpty", Warn: true, Err: reason})
	a.terminalFailed(termview.Failure{Event: "terminal.session.start_failed", Stage: "spawn", Warn: true, Err: reason})
	if len(log.events) != 2 {
		t.Fatalf("logged %d events, want 2", len(log.events))
	}
	fallback, start := log.events[0], log.events[1]
	if fallback.level != core.LevelWarn || fallback.event != backgroundFailedEvent || fallback.fields["operation"] != "terminal_conpty" {
		t.Errorf("the fallback was logged as %v %s %v", fallback.level, fallback.event, fallback.fields)
	}
	if _, ok := fallback.fields["stage"]; ok {
		t.Errorf("the fallback carries a stage: %v", fallback.fields)
	}
	if _, ok := fallback.fields["error"]; !ok {
		t.Errorf("the fallback carries no error: %v", fallback.fields)
	}
	if start.fields["stage"] != "spawn" {
		t.Errorf("the failed start carries stage %v", start.fields["stage"])
	}
	if _, ok := start.fields["operation"]; ok {
		t.Errorf("the failed start carries an operation: %v", start.fields)
	}
}
