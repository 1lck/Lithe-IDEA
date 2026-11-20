package core

/*
#cgo LDFLAGS: -llithe_core
#include <stdlib.h>
#include <string.h>
#include "lithe_core.h"
*/
import "C"

import (
	"runtime"
	"unsafe"
)

// GitAskPass runs this process as the AskPass helper GitAskPassRequest detected: Core sends
// prompt to the Lithe request that started Git, waits for the user's answer, prints it on
// standard output for Git or SSH and returns the exit status, 0 when it printed an answer and 1
// when there is none (cancelled, expired or refused). Call it first in main and exit with its
// result: a helper process opens no window, log or store.
func GitAskPass(prompt string) int {
	cPrompt := C.CString(prompt)
	defer C.free(unsafe.Pointer(cPrompt))
	return int(C.lithe_core_git_askpass(cPrompt))
}

// classifyTextBytes borrows the Go byte slice only for the synchronous Core
// call. The slice contains no pointers, and Core neither retains nor mutates it.
func classifyTextBytes(data []byte) int {
	result := C.lithe_core_is_plain_text((*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(data))), C.size_t(len(data)))
	runtime.KeepAlive(data)
	return int(result)
}

// executeJSON sends one JSON request to the kernel and returns its JSON response. It returns
// nil when the kernel produced no response at all.
//
// The request is copied into C memory for the duration of the call and the kernel's answer is
// copied into Go memory before the kernel's buffer is released, so neither side keeps a pointer
// into the other's memory.
//
// Concurrency: lithe_core_execute_json may be called from several threads at once. The entry
// point takes no process-wide lock; the only per-request state is the cancellation scope, which
// the kernel keeps in thread-local storage for the duration of this synchronous call (cgo runs
// the whole call on one OS thread, as that requires), and the table of in-flight operations
// that lithe_core_cancel reads is mutex-guarded.
func executeJSON(request []byte) []byte {
	cRequest := C.CString(string(request))
	defer C.free(unsafe.Pointer(cRequest))

	response := C.lithe_core_execute_json(cRequest)
	if response == nil {
		return nil
	}
	defer C.lithe_core_free_string(response)
	return C.GoBytes(unsafe.Pointer(response), C.int(C.strlen(response)))
}

// executeDocumentJSON borrows immutable source bytes for the synchronous Core call.
// Only the small request and bounded result are copied across the C ABI. Core never
// retains the Go pointer, and the slice contains no Go pointers.
func executeDocumentJSON(request, source []byte) []byte {
	cRequest := C.CString(string(request))
	defer C.free(unsafe.Pointer(cRequest))
	response := C.lithe_core_execute_document_json(cRequest, (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(source))), C.size_t(len(source)))
	runtime.KeepAlive(source)
	if response == nil {
		return nil
	}
	defer C.lithe_core_free_string(response)
	return C.GoBytes(unsafe.Pointer(response), C.int(C.strlen(response)))
}

// cancelOperation asks the kernel to cancel the in-flight request whose operationId is
// operationID. It reports whether the kernel found an active operation with that id: the C
// function returns 1 when it did and 0 when it did not (the operation already finished, has not
// started yet, or the id is NULL). Cancellation is cooperative; the cancelled request still has
// to reach its next cancellation check before it answers with the "cancelled" error code.
//
// It is safe to call from any thread, including while the request runs on another one.
func cancelOperation(operationID string) bool {
	cID := C.CString(operationID)
	defer C.free(unsafe.Pointer(cID))
	return C.lithe_core_cancel(cID) == 1
}

// coreVersion returns the kernel's C ABI version string. The kernel returns a pointer to a
// static NUL-terminated string that lives as long as the process, so it is copied but must
// never be passed to lithe_core_free_string.
func coreVersion() string {
	return C.GoString(C.lithe_core_version())
}
