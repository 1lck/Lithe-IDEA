//! Ownership-safe C ABI wrappers for the JSON command and cancellation APIs.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;

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
