package core

/*
#include <stdint.h>
#include "lithe_core.h"

extern void goLitheLogWake(uintptr_t identity);

static void lithe_go_log_wake(void *context) {
    goLitheLogWake((uintptr_t)context);
}

static void lithe_go_install_log_waker(uintptr_t identity) {
    lithe_core_install_log_waker(lithe_go_log_wake, (void *)identity);
}

static int32_t lithe_go_remove_log_waker(uintptr_t identity) {
    return lithe_core_remove_log_waker((void *)identity);
}
*/
import "C"

import (
	"fmt"
	"runtime/debug"
	"sync"
	"sync/atomic"
)

// RecoveredPanic is a panic the client recovered in a callback Core made into Go, where
// unwinding would cross into Rust and abort the process.
type RecoveredPanic struct {
	// Boundary is the catalog token of the callback that recovered it: core:log-waker for the
	// waker, core:events-observer for a request's event observer.
	Boundary string
	// Value is the panic value as text.
	Value string
	// Stack is the panicking goroutine's stack as runtime/debug.Stack prints it.
	Stack []byte
}

// logWatch is one WatchCoreEvents registration.
type logWatch struct {
	wake      func()
	recovered func(RecoveredPanic)
}

// C only receives integer identities; the registry owns the Go callbacks until Core has
// removed the waker and no longer calls it.
var logWakers sync.Map
var logWakerID atomic.Uint64

// currentLogWatch is the registration Core's single, process-wide waker belongs to, so it
// changes exactly when that waker does. A request's event observer has no writer of its own,
// so the panics it recovers are reported here: this is not a second log sink but the one the
// writer installed with WatchCoreEvents.
var currentLogWatch atomic.Pointer[logWatch]

// WatchCoreEvents asks the kernel to call wake when it queues a fact for the host's writer
// while the previous drain has not been followed by a wake yet, and at once when facts are
// already queued. wake runs on a kernel thread while the kernel holds its waker lock: it must
// only schedule a drain and never call into the kernel.
//
// recovered receives every panic the client recovers in a callback Core makes into Go, in
// wake and in the event observer of any request, on the thread Core called. It must return
// quickly and must neither block nor call into the kernel; its own panic is dropped.
//
// A later watch replaces this one. stop removes the waker; once it returns wake is not running
// and is never called again, and calling stop again does nothing.
func (c *Client) WatchCoreEvents(wake func(), recovered func(RecoveredPanic)) (stop func()) {
	watch := &logWatch{wake: wake, recovered: recovered}
	var id uintptr
	for {
		id = uintptr(logWakerID.Add(1))
		if id != 0 {
			if _, loaded := logWakers.LoadOrStore(id, watch); !loaded {
				break
			}
		}
	}
	currentLogWatch.Store(watch)
	C.lithe_go_install_log_waker(C.uintptr_t(id))
	var once sync.Once
	return func() {
		once.Do(func() {
			C.lithe_go_remove_log_waker(C.uintptr_t(id))
			logWakers.Delete(id)
			currentLogWatch.CompareAndSwap(watch, nil)
		})
	}
}

// report hands a panic recovered at boundary to the watch. It must be called from the deferred
// function that recovered the panic, so the stack is the panicking one. It runs inside a
// callback Core made, so its own panic, including one formatting the value, is dropped instead
// of unwinding into Rust. A nil watch, while no writer observes Core, drops the panic.
func (w *logWatch) report(boundary string, recovered any) {
	if w == nil || w.recovered == nil {
		return
	}
	defer func() { _ = recover() }()
	w.recovered(RecoveredPanic{Boundary: boundary, Value: fmt.Sprint(recovered), Stack: debug.Stack()})
}

//export goLitheLogWake
func goLitheLogWake(identity C.uintptr_t) {
	wakeLogWatch(uintptr(identity))
}

// wakeLogWatch calls the wake of the watch registered as identity, if any.
func wakeLogWatch(identity uintptr) {
	value, ok := logWakers.Load(identity)
	if !ok {
		return
	}
	watch := value.(*logWatch)
	// A Go panic must never unwind through Rust; a lost wake only delays the next drain.
	defer func() {
		if recovered := recover(); recovered != nil {
			watch.report("core:log-waker", recovered)
		}
	}()
	watch.wake()
}
