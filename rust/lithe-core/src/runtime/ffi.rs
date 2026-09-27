//! Ownership-safe C ABI wrappers for the JSON command and cancellation APIs.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

struct AgentFFIHandle {
    handle: lithe_agent_host::AgentHandle,
    callback: Arc<
        Mutex<
            Option<(
                unsafe extern "C" fn(*const c_char, *mut std::ffi::c_void),
                usize,
            )>,
        >,
    >,
}

/// Returns a pointer to the static, NUL-terminated Core ABI version.
///
/// The pointer remains valid for the lifetime of the process and must not be
/// passed to [`lithe_core_free_string`].
#[no_mangle]
pub extern "C" fn lithe_core_version() -> *const c_char {
    static VERSION: &[u8] = b"0.1.0\0";
    VERSION.as_ptr().cast()
}

/// Executes one JSON request through the stable C ABI.
///
/// The returned string is owned by the caller and must be released exactly
/// once with [`lithe_core_free_string`].
///
/// # Safety
///
/// `request` must be null or point to a readable, NUL-terminated byte string
/// for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn lithe_core_execute_json(request: *const c_char) -> *mut c_char {
    if request.is_null() {
        return response_pointer(
            r#"{"id":null,"ok":false,"error":{"code":"invalid_request","message":"Request pointer is null"}}"#,
        );
    }
    let request = CStr::from_ptr(request).to_string_lossy();
    response_pointer(&crate::execute_json(&request))
}

/// Loads the merged language-provider catalog for an optional workspace root.
///
/// The returned string is owned by the caller and must be released exactly
/// once with [`lithe_core_free_string`].
///
/// # Safety
///
/// `workspace_root` must be null or point to a readable, NUL-terminated byte
/// string for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn lithe_core_lsp_provider_catalog_json(
    workspace_root: *const c_char,
) -> *mut c_char {
    let root = if workspace_root.is_null() {
        None
    } else {
        let value = CStr::from_ptr(workspace_root).to_string_lossy();
        if value.trim().is_empty() {
            None
        } else {
            Some(PathBuf::from(value.as_ref()))
        }
    };
    response_pointer(&crate::lsp::provider_catalog_json(root.as_deref()))
}

/// Requests cooperative cancellation of an in-flight operation. The call is
/// thread-safe and returns 1 when an active operation was found.
///
/// # Safety
///
/// `operation_id` must be null or point to a readable, NUL-terminated byte
/// string for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn lithe_core_cancel(operation_id: *const c_char) -> i32 {
    if operation_id.is_null() {
        return 0;
    }
    let operation_id = CStr::from_ptr(operation_id).to_string_lossy();
    crate::cancel_operation(&operation_id) as i32
}

/// Releases a string returned by a Core C ABI function.
///
/// # Safety
///
/// `value` must be null or a pointer returned by this library that has not
/// already been freed. Static pointers such as [`lithe_core_version`] are not
/// owned strings and must not be passed here.
#[no_mangle]
pub unsafe extern "C" fn lithe_core_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

fn response_pointer(value: &str) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("{\"id\":null,\"ok\":false}").expect("fallback is valid"))
        .into_raw()
}

/// Executes JSON with request-scoped Git diagnostics and Agent install progress. Each event string
/// is borrowed only during the callback; the response uses the normal ownership.
///
/// # Safety
///
/// `request` follows `lithe_core_execute_json`'s contract. `callback` must not
/// unwind, and `context` must remain valid until this synchronous call returns.
/// Callbacks run serially on the calling thread and must copy retained strings.
#[no_mangle]
pub unsafe extern "C" fn lithe_core_execute_json_with_events(
    request: *const c_char,
    callback: Option<unsafe extern "C" fn(*const c_char, *mut std::ffi::c_void)>,
    context: *mut std::ffi::c_void,
) -> *mut c_char {
    let Some(callback) = callback else {
        return lithe_core_execute_json(request);
    };
    if request.is_null() {
        return lithe_core_execute_json(request);
    }
    let request = CStr::from_ptr(request).to_string_lossy();
    // The callback is scoped to this synchronous call, never a worker thread.
    let context_address = context as usize;
    let sink = std::sync::Arc::new(move |event: &str| {
        if let Ok(event) = CString::new(event) {
            callback(event.as_ptr(), context_address as *mut std::ffi::c_void);
        }
    });
    response_pointer(&crate::execute_json_with_events(&request, sink))
}

/// Runs the native authentication helper without initializing the application.
///
/// # Safety
/// `prompt` must be a readable NUL-terminated string for this synchronous call.
#[no_mangle]
pub unsafe extern "C" fn lithe_core_git_askpass(prompt: *const c_char) -> i32 {
    if prompt.is_null() {
        return 1;
    }
    crate::git_askpass_main(&CStr::from_ptr(prompt).to_string_lossy())
}

/// Starts one ACP agent connection and delivers UTF-8 JSON events on a worker thread.
///
/// The returned opaque handle must be closed once with [`lithe_agent_close`].
///
/// # Safety
///
/// `configuration` must be readable NUL-terminated JSON. `callback` must not
/// unwind or retain its borrowed event pointer. `context` must remain valid
/// until `lithe_agent_close` returns. Other handle calls must not race close.
#[no_mangle]
pub unsafe extern "C" fn lithe_agent_open_json(
    configuration: *const c_char,
    callback: Option<unsafe extern "C" fn(*const c_char, *mut std::ffi::c_void)>,
    context: *mut std::ffi::c_void,
) -> *mut std::ffi::c_void {
    let Some(callback) = callback else {
        return std::ptr::null_mut();
    };
    if configuration.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(launch) = serde_json::from_slice::<lithe_agent_host::AgentLaunch>(
        CStr::from_ptr(configuration).to_bytes(),
    ) else {
        return std::ptr::null_mut();
    };
    let callback_state = Arc::new(Mutex::new(Some((callback, context as usize))));
    let state = callback_state.clone();
    let emit = Arc::new(move |event: lithe_agent_host::AgentEvent| {
        if let Ok(json) = serde_json::to_string(&event) {
            if let Ok(json) = CString::new(json) {
                // Holding the lock lets close revoke the callback only after an
                // in-flight call returns, so Swift can then release context.
                if let Ok(state) = state.lock() {
                    if let Some((callback, context)) = *state {
                        callback(json.as_ptr(), context as *mut std::ffi::c_void);
                    }
                }
            }
        }
    });
    match lithe_agent_host::AgentHandle::open(launch, emit) {
        Ok(handle) => Box::into_raw(Box::new(AgentFFIHandle {
            handle,
            callback: callback_state,
        }))
        .cast(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Queues one UTF-8 JSON command on an ACP connection; returns 1 when accepted.
///
/// Commands follow `shared/fixtures/agent/acp-events-v1.json`. Results arrive
/// asynchronously as events; 0 means the JSON was invalid, the permission
/// request is gone, or the connection has stopped.
///
/// # Safety
/// `handle` must be an open handle from `lithe_agent_open_json`; `command` must
/// be a readable NUL-terminated string for this call.
#[no_mangle]
pub unsafe extern "C" fn lithe_agent_send_json(
    handle: *mut std::ffi::c_void,
    command: *const c_char,
) -> i32 {
    if handle.is_null() || command.is_null() {
        return 0;
    }
    let handle = &*(handle as *mut AgentFFIHandle);
    let Ok(command) = serde_json::from_slice::<lithe_agent_host::AgentCommand>(
        CStr::from_ptr(command).to_bytes(),
    ) else {
        return 0;
    };
    handle.handle.send(command).is_ok() as i32
}

/// Revokes callbacks, stops the agent tree, and frees an ACP handle.
///
/// # Safety
/// `handle` must be null or an open handle from `lithe_agent_open_json`. Calls
/// using the same handle must finish before close; the handle is invalid after.
#[no_mangle]
pub unsafe extern "C" fn lithe_agent_close(handle: *mut std::ffi::c_void) {
    if handle.is_null() {
        return;
    }
    let handle = Box::from_raw(handle as *mut AgentFFIHandle);
    if let Ok(mut callback) = handle.callback.lock() {
        callback.take();
    }
    handle.handle.close();
}
