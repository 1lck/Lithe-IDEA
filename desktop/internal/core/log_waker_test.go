package core

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestObserverPanicIsReportedToTheWatch(t *testing.T) {
	client := NewClient()
	reports := make(chan RecoveredPanic, 4)
	stop := client.WatchCoreEvents(func() {}, func(p RecoveredPanic) {
		select {
		case reports <- p:
		default:
		}
	})
	observationErr, requestErr := client.ExecuteWithEvents(testContext(t), "core.ping", nil, nil, func(json.RawMessage) {
		panicFixture()
	})
	if !errors.Is(observationErr, ErrCoreEventsLost) || requestErr != nil {
		t.Fatalf("observe=%v request=%v", observationErr, requestErr)
	}
	// The observer reports on the thread Core called, before the request returns.
	select {
	case p := <-reports:
		if p.Boundary != "core:events-observer" || p.Value != "fixture" ||
			!strings.HasPrefix(LogPanicStack(p.Stack), "core.panicFixture log_text_test.go:") {
			t.Fatalf("reported %q %q %q", p.Boundary, p.Value, LogPanicStack(p.Stack))
		}
	default:
		t.Fatal("the observer's panic was not reported")
	}

	stop()
	if currentLogWatch.Load() != nil {
		t.Fatal("the watch is still current after stop")
	}
	// Without a watch the panic is dropped, and the request still answers.
	observationErr, requestErr = client.ExecuteWithEvents(testContext(t), "core.ping", nil, nil, func(json.RawMessage) {
		panicFixture()
	})
	if !errors.Is(observationErr, ErrCoreEventsLost) || requestErr != nil || len(reports) != 0 {
		t.Fatalf("observe=%v request=%v reports=%d after stop", observationErr, requestErr, len(reports))
	}
}

func TestWakerPanicIsReportedToTheWatch(t *testing.T) {
	var reports []RecoveredPanic
	watch := &logWatch{wake: panicFixture, recovered: func(p RecoveredPanic) { reports = append(reports, p) }}
	// WatchCoreEvents counts identities up from 1, so a test never meets this one.
	const id = ^uintptr(0)
	logWakers.Store(id, watch)
	defer logWakers.Delete(id)

	wakeLogWatch(id)
	if len(reports) != 1 || reports[0].Boundary != "core:log-waker" || reports[0].Value != "fixture" ||
		!strings.HasPrefix(LogPanicStack(reports[0].Stack), "core.panicFixture log_text_test.go:") {
		t.Fatalf("reports = %+v", reports)
	}

	// A receiver that panics itself must not unwind into Core either.
	watch.recovered = func(RecoveredPanic) { panic("receiver broke") }
	wakeLogWatch(id)
	// Neither must a watch without a receiver, nor an identity Core no longer knows.
	watch.recovered = nil
	wakeLogWatch(id)
	wakeLogWatch(id - 1)
}
