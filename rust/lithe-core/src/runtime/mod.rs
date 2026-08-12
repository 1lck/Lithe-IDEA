//! JSON command dispatch and the exported C ABI.

mod dispatcher;
mod ffi;

pub(crate) use dispatcher::execute_json;
