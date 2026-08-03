use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[no_mangle]
pub extern "C" fn lithe_core_version() -> *const c_char {
    static VERSION: &[u8] = b"0.1.0\0";
    VERSION.as_ptr().cast()
}

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
