//! C ABI for the Flutter test (dart:ffi), like veilid-flutter's bridge.
//!
//! `p2pc_mls_poc_run` runs the minimal scenario and returns a buffer owned by
//! Rust: 8 bytes little-endian length, then that many bytes of UTF-8 JSON
//! (so Dart needs no allocator). Free it with `p2pc_mls_poc_free`. A panic
//! never crosses the boundary: it becomes `{"ok":false,...}`.

use std::panic::{catch_unwind, AssertUnwindSafe};

const HEADER: usize = 8;

/// Runs the scenario; returns `[len: u64 LE][json]`.
#[no_mangle]
pub extern "C" fn p2pc_mls_poc_run() -> *mut u8 {
    let json = catch_unwind(AssertUnwindSafe(|| {
        serde_json::to_vec(&crate::scenario::run_minimal()).unwrap_or_default()
    }))
    .unwrap_or_else(|_| {
        br#"{"ok":false,"steps":[{"name":"panic","ok":false,"detail":"panicked"}]}"#.to_vec()
    });
    to_buffer(json)
}

/// Runs the scenario `runs` times with timings and memory
/// ([`crate::bench`]); returns `[len: u64 LE][json]`. Free it with
/// [`p2pc_mls_poc_free`].
#[no_mangle]
pub extern "C" fn p2pc_mls_poc_bench(runs: u32) -> *mut u8 {
    let json = catch_unwind(AssertUnwindSafe(|| {
        serde_json::to_vec(&crate::bench::run(runs as usize)).unwrap_or_default()
    }))
    .unwrap_or_else(|_| br#"{"ok":false,"error":"panicked"}"#.to_vec());
    to_buffer(json)
}

fn to_buffer(json: Vec<u8>) -> *mut u8 {
    let mut buf = Vec::with_capacity(HEADER + json.len());
    buf.extend_from_slice(&(json.len() as u64).to_le_bytes());
    buf.extend_from_slice(&json);
    Box::into_raw(buf.into_boxed_slice()) as *mut u8
}

/// Frees a buffer returned by [`p2pc_mls_poc_run`].
///
/// # Safety
/// `ptr` must come from one `p2pc_mls_poc_run` call and be freed once.
#[no_mangle]
pub unsafe extern "C" fn p2pc_mls_poc_free(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: the header holds the JSON length written by p2pc_mls_poc_run,
    // so the boxed slice is rebuilt with its exact original length.
    unsafe {
        let mut len = [0u8; HEADER];
        std::ptr::copy_nonoverlapping(ptr, len.as_mut_ptr(), HEADER);
        let total = HEADER + u64::from_le_bytes(len) as usize;
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            ptr, total,
        )));
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn round_trip_through_the_c_abi() {
        let ptr = super::p2pc_mls_poc_run();
        // SAFETY: valid buffer from p2pc_mls_poc_run, read then freed once.
        let report: serde_json::Value = unsafe {
            let len = u64::from_le_bytes(*(ptr as *const [u8; 8])) as usize;
            let json = std::slice::from_raw_parts(ptr.add(8), len);
            let v = serde_json::from_slice(json).unwrap();
            super::p2pc_mls_poc_free(ptr);
            v
        };
        assert_eq!(report["ok"], true, "{report}");
    }
}
