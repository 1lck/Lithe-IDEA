package core

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "lithe_core.h"

extern void goLitheRequestEvent(char *event, uintptr_t identity);

static void lithe_go_request_event(const char *event, void *context) {
    goLitheRequestEvent((char *)event, (uintptr_t)context);
}

static char *lithe_go_execute_with_events(const char *request, uintptr_t identity) {
    return lithe_core_execute_json_with_events(request, lithe_go_request_event, (void *)identity);
}
*/
import "C"

import (
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"unsafe"
)

// ErrCoreEventsLost means the request's event observer could not see every
// event. The request's own result must still be handled separately.
var ErrCoreEventsLost = errors.New("core request events could not be observed completely")

const coreRequestEventLimit = 4 << 20

type coreRequestObserver struct {
	accept func(json.RawMessage)
	failed atomic.Bool
}

// C only receives integer identities; the registry owns Go observers until the
// synchronous Core call returns and has finished every callback.
var coreRequestObservers sync.Map
var coreRequestObserverID atomic.Uint64

func registerCoreRequestObserver(observer *coreRequestObserver) uintptr {
	for {
		id := uintptr(coreRequestObserverID.Add(1))
		if id != 0 {
			if _, loaded := coreRequestObservers.LoadOrStore(id, observer); !loaded {
				return id
			}
		}
	}
}

func executeJSONWithEvents(request []byte, observer func(json.RawMessage)) ([]byte, error) {
	state := &coreRequestObserver{accept: observer}
	id := registerCoreRequestObserver(state)
	defer coreRequestObservers.Delete(id)
	input := C.CString(string(request))
	defer C.free(unsafe.Pointer(input))
	response := C.lithe_go_execute_with_events(input, C.uintptr_t(id))
	var data []byte
	if response != nil {
		defer C.lithe_core_free_string(response)
		data = C.GoBytes(unsafe.Pointer(response), C.int(C.strlen(response)))
	}
	if state.failed.Load() {
		return data, ErrCoreEventsLost
	}
	return data, nil
}

//export goLitheRequestEvent
func goLitheRequestEvent(event *C.char, identity C.uintptr_t) {
	value, ok := coreRequestObservers.Load(uintptr(identity))
	if !ok {
		return
	}
	observer := value.(*coreRequestObserver)
	if observer.failed.Load() {
		return
	}
	// A Go panic must never unwind through Rust. The final request result is
	// still returned separately because Core may already have changed state.
	defer func() {
		if recover() != nil {
			observer.failed.Store(true)
		}
	}()
	if event == nil {
		observer.failed.Store(true)
		return
	}
	length := C.strlen(event)
	if length > C.size_t(coreRequestEventLimit) {
		observer.failed.Store(true)
		return
	}
	observer.accept(json.RawMessage(C.GoBytes(unsafe.Pointer(event), C.int(length))))
}
