package core

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "lithe_core.h"

extern void goLitheAgentEvent(char *event, uintptr_t identity);

static void lithe_go_agent_event(const char *event, void *context) {
    goLitheAgentEvent((char *)event, (uintptr_t)context);
}

static void *lithe_go_agent_open(const char *configuration, uintptr_t identity) {
    return lithe_agent_open_json(configuration, lithe_go_agent_event, (void *)identity);
}
*/
import "C"

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"unsafe"
)

// Only integer identities cross C; the registry owns Go queues until Core has
// revoked callbacks and returned from close. C never holds a Go pointer.
var agentQueues sync.Map
var agentQueueID atomic.Uint64

func registerAgentQueue(queue *agentEventQueue) uintptr {
	for {
		id := uintptr(agentQueueID.Add(1))
		if id != 0 {
			if _, loaded := agentQueues.LoadOrStore(id, queue); !loaded {
				return id
			}
		}
	}
}

func unregisterAgentQueue(id uintptr) { agentQueues.Delete(id) }

func openNativeAgent(launch json.RawMessage, id uintptr) unsafe.Pointer {
	text := C.CString(string(launch))
	defer C.free(unsafe.Pointer(text))
	return C.lithe_go_agent_open(text, C.uintptr_t(id))
}

func sendNativeAgent(handle unsafe.Pointer, command json.RawMessage) bool {
	text := C.CString(string(command))
	defer C.free(unsafe.Pointer(text))
	return C.lithe_agent_send_json(handle, text) == 1
}

func closeNativeAgent(handle unsafe.Pointer) { C.lithe_agent_close(handle) }

//export goLitheAgentEvent
func goLitheAgentEvent(event *C.char, identity C.uintptr_t) {
	value, ok := agentQueues.Load(uintptr(identity))
	if !ok || event == nil {
		return
	}
	queue := value.(*agentEventQueue)
	length := C.strlen(event)
	if length > C.size_t(agentEventSingleLimit) {
		queue.fail()
		return
	}
	size := int(length)
	if !queue.reserve(size) {
		return
	}
	queue.publish(json.RawMessage(C.GoBytes(unsafe.Pointer(event), C.int(size))))
}
