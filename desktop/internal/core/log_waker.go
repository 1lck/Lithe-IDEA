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
	"sync"
	"sync/atomic"
)

// C only receives integer identities; the registry owns the Go callbacks until Core has
// removed the waker and no longer calls it.
var logWakers sync.Map
var logWakerID atomic.Uint64

// WatchCoreEvents asks the kernel to call wake when it queues a fact for the host's writer
// while the previous drain has not been followed by a wake yet, and at once when facts are
// already queued. wake runs on a kernel thread while the kernel holds its waker lock: it must
// only schedule a drain and never call into the kernel. A later watch replaces this one. stop
// removes the waker; once it returns wake is not running and is never called again, and
// calling stop again does nothing.
func (c *Client) WatchCoreEvents(wake func()) (stop func()) {
	var id uintptr
	for {
		id = uintptr(logWakerID.Add(1))
		if id != 0 {
			if _, loaded := logWakers.LoadOrStore(id, wake); !loaded {
				break
			}
		}
	}
	C.lithe_go_install_log_waker(C.uintptr_t(id))
	var once sync.Once
	return func() {
		once.Do(func() {
			C.lithe_go_remove_log_waker(C.uintptr_t(id))
			logWakers.Delete(id)
		})
	}
}

//export goLitheLogWake
func goLitheLogWake(identity C.uintptr_t) {
	value, ok := logWakers.Load(uintptr(identity))
	if !ok {
		return
	}
	// A Go panic must never unwind through Rust; a lost wake only delays the next drain.
	defer func() { _ = recover() }()
	value.(func())()
}
