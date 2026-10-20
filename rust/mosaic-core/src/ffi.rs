//! Stable C ABI.
//!
//! Every call accepts and returns UTF-8 JSON (except `mosaic_core_version`). A
//! response is always an object:
//!
//! ```json
//! { "ok": true, "result": { ... } }
//! { "ok": false, "error": "unknown item: abc" }
//! ```
//!
//! Strings returned here are owned by Rust and must be released with
//! `mosaic_string_free`. Panics are caught so malformed input can never unwind into
//! Swift or terminate the host process.

use crate::book::{plan_book, BookRequest};
use crate::index::{
    ClusterRequest, DuplicateRequest, IndexItem, MosaicIndex, QueryRequest, SelectRequest,
};
use crate::layout::{layout_collage, CollageRequest};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

fn failure(message: &str) -> *mut c_char {
    let value = json!({"ok": false, "error": message});
    to_c_string(&value)
}

fn to_c_string(value: &Value) -> *mut c_char {
    match CString::new(value.to_string()) {
        Ok(value) => value.into_raw(),
        Err(_) => CString::new(r#"{"ok":false,"error":"response contained a null byte"}"#)
            .expect("static JSON is valid")
            .into_raw(),
    }
}

fn call<F>(work: F) -> *mut c_char
where
    F: FnOnce() -> Result<Value, String> + std::panic::UnwindSafe,
{
    match catch_unwind(AssertUnwindSafe(work)) {
        Ok(Ok(value)) => to_c_string(&json!({"ok": true, "result": value})),
        Ok(Err(message)) => failure(&message),
        Err(_) => failure("internal error"),
    }
}

unsafe fn input<T: DeserializeOwned>(value: *const c_char) -> Result<T, String> {
    if value.is_null() {
        return Err("missing JSON input".into());
    }
    let value = CStr::from_ptr(value)
        .to_str()
        .map_err(|_| "input was not valid UTF-8".to_string())?;
    serde_json::from_str(value).map_err(|error| format!("invalid JSON: {error}"))
}

fn index_ref<'a>(index: *mut MosaicIndex) -> Result<&'a MosaicIndex, String> {
    if index.is_null() {
        Err("missing index handle".into())
    } else {
        Ok(unsafe { &*index })
    }
}

#[no_mangle]
pub extern "C" fn mosaic_core_version() -> *mut c_char {
    CString::new(env!("CARGO_PKG_VERSION"))
        .expect("version is valid")
        .into_raw()
}

#[no_mangle]
pub extern "C" fn mosaic_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}

#[no_mangle]
pub extern "C" fn mosaic_index_new() -> *mut MosaicIndex {
    Box::into_raw(Box::new(MosaicIndex::new()))
}

#[no_mangle]
pub extern "C" fn mosaic_index_free(index: *mut MosaicIndex) {
    if !index.is_null() {
        unsafe {
            drop(Box::from_raw(index));
        }
    }
}

#[no_mangle]
pub extern "C" fn mosaic_index_upsert(index: *mut MosaicIndex, json: *const c_char) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        let request: UpsertRequest = unsafe { input(json)? };
        let result = index.upsert(request.items)?;
        Ok(json!(result))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_index_remove(index: *mut MosaicIndex, json: *const c_char) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        let request: RemoveRequest = unsafe { input(json)? };
        let removed = index.remove(&request.ids)?;
        Ok(json!({"removed": removed}))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_index_clear(index: *mut MosaicIndex) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        index.clear()?;
        Ok(json!({"cleared": true}))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_index_query(index: *mut MosaicIndex, json: *const c_char) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        let request: QueryRequest = unsafe { input(json)? };
        let results = index.query(&request)?;
        Ok(json!({"results": results}))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_index_clusters(index: *mut MosaicIndex, json: *const c_char) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        let request: ClusterRequest = unsafe { input(json)? };
        let clusters = index.clusters(&request)?;
        Ok(json!({"clusters": clusters}))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_index_select(index: *mut MosaicIndex, json: *const c_char) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        let request: SelectRequest = unsafe { input(json)? };
        let selected = index.select(&request)?;
        Ok(json!({"selected": selected}))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_index_duplicates(index: *mut MosaicIndex, json: *const c_char) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        let request: DuplicateRequest = unsafe { input(json)? };
        let groups = index.duplicates(&request)?;
        Ok(json!({"groups": groups}))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_index_stats(index: *mut MosaicIndex, _json: *const c_char) -> *mut c_char {
    call(move || {
        let index = index_ref(index)?;
        let stats = index.stats()?;
        Ok(json!(stats))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_collage_layout(json: *const c_char) -> *mut c_char {
    call(move || {
        let request: CollageRequest = unsafe { input(json)? };
        let layout = layout_collage(&request)?;
        Ok(json!(layout))
    })
}

#[no_mangle]
pub extern "C" fn mosaic_book_plan(json: *const c_char) -> *mut c_char {
    call(move || {
        let request: BookRequest = unsafe { input(json)? };
        let plan = plan_book(&request)?;
        Ok(json!(plan))
    })
}

#[derive(serde::Deserialize)]
struct UpsertRequest {
    items: Vec<IndexItem>,
}

#[derive(serde::Deserialize)]
struct RemoveRequest {
    ids: Vec<String>,
}
