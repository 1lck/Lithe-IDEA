//! Minimal C ABI exported by the wasm build, without `wasm-bindgen`.
//!
//! The host copies a UTF-8 JSON request into memory obtained from `lithe_rules_alloc`, calls
//! `lithe_rules_execute`, reads the response bytes from the returned pointer (its length comes
//! from `lithe_rules_result_len`), and frees both buffers with `lithe_rules_dealloc`.
//! Requests and responses use the Core envelope, see [`crate::execute_json`].
//!
//! wasm32-unknown-unknown modules are single threaded, so the last-result length lives in a plain
//! atomic rather than behind a lock.

use std::sync::atomic::{AtomicUsize, Ordering};

static LAST_RESULT_LEN: AtomicUsize = AtomicUsize::new(0);

/// Allocates `len` writable bytes for the host and returns their address.
#[no_mangle]
pub extern "C" fn lithe_rules_alloc(len: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; len.max(1)].into_boxed_slice()).cast::<u8>()
}

/// Releases a buffer previously handed out by `lithe_rules_alloc` or `lithe_rules_execute`.
///
/// # Safety
///
/// `pointer` and `len` must be exactly the address and requested length of a live buffer from
/// this module, and the buffer must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn lithe_rules_dealloc(pointer: *mut u8, len: usize) {
    if !pointer.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            pointer,
            len.max(1),
        )));
    }
}

/// Runs one JSON request and returns the address of the JSON response.
///
/// The response length is available from `lithe_rules_result_len` until the next call.
///
/// # Safety
///
/// `pointer` must address `len` initialized bytes inside this module's memory.
#[no_mangle]
pub unsafe extern "C" fn lithe_rules_execute(pointer: *const u8, len: usize) -> *mut u8 {
    let request = std::slice::from_raw_parts(pointer, len);
    let response = match std::str::from_utf8(request) {
        Ok(text) => crate::execute_json(text),
        Err(_) => r#"{"id":null,"ok":false,"error":{"code":"invalid_request","message":"Request is not valid UTF-8"}}"#.to_string(),
    };
    let bytes = response.into_bytes();
    let response_len = bytes.len();
    // Copy into a buffer sized exactly like the host-visible length, so `lithe_rules_dealloc`
    // can release it with that length.
    let output = lithe_rules_alloc(response_len);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, response_len);
    LAST_RESULT_LEN.store(response_len, Ordering::Relaxed);
    output
}

/// Length in bytes of the response returned by the most recent `lithe_rules_execute` call.
#[no_mangle]
pub extern "C" fn lithe_rules_result_len() -> usize {
    LAST_RESULT_LEN.load(Ordering::Relaxed)
}
