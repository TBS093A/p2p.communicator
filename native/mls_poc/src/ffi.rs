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

// ------------------------------------------------------------ sessions
//
// The app's API (crate::api): one opaque handle per conversation member.
// Every call is synchronous and fast (no networking); the host runs them off
// the UI thread. Inputs are UTF-8 (JSON or bytes) passed as pointer +
// length; outputs are buffers as above.

use crate::api::{RoundIn, Session};

/// # Safety
/// `ptr` must point to `len` readable bytes (or be null with `len == 0`).
unsafe fn input<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: guaranteed by the caller.
    unsafe { std::slice::from_raw_parts(ptr, len) }
}

fn json_buffer(v: &impl serde::Serialize) -> *mut u8 {
    to_buffer(serde_json::to_vec(v).unwrap_or_else(|_| b"null".to_vec()))
}

fn guarded(f: impl FnOnce() -> *mut u8) -> *mut u8 {
    catch_unwind(AssertUnwindSafe(f))
        .unwrap_or_else(|_| to_buffer(br#"{"ok":false,"error":"panicked"}"#.to_vec()))
}

/// A new member (fresh conversation identity). Free with
/// [`p2pc_core_close`].
///
/// # Safety
/// `name`/`len` as in `input`.
#[no_mangle]
pub unsafe extern "C" fn p2pc_core_new(name: *const u8, len: usize) -> *mut Session {
    // SAFETY: forwarded from the caller.
    let name = String::from_utf8_lossy(unsafe { input(name, len) }).into_owned();
    catch_unwind(|| Box::into_raw(Box::new(Session::new(&name)))).unwrap_or(std::ptr::null_mut())
}

/// A member restored from [`p2pc_core_save`]'s bytes; null if they are not
/// a valid saved state.
///
/// # Safety
/// `ptr`/`len` as in `input`.
#[no_mangle]
pub unsafe extern "C" fn p2pc_core_restore(ptr: *const u8, len: usize) -> *mut Session {
    // SAFETY: forwarded from the caller.
    let bytes = unsafe { input(ptr, len) }.to_vec();
    catch_unwind(move || match Session::restore(&bytes) {
        Ok(s) => Box::into_raw(Box::new(s)),
        Err(_) => std::ptr::null_mut(),
    })
    .unwrap_or(std::ptr::null_mut())
}

/// The member's whole state, to persist (encrypted) before performing the
/// writes of a committed round. Returns a buffer of raw bytes.
///
/// # Safety
/// `s` must come from `p2pc_core_new`/`p2pc_core_restore` and not be closed.
#[no_mangle]
pub unsafe extern "C" fn p2pc_core_save(s: *mut Session) -> *mut u8 {
    // SAFETY: guaranteed by the caller.
    let s = unsafe { &*s };
    guarded(|| to_buffer(s.save()))
}

/// One round (crate::api): request JSON in, reply JSON out.
///
/// # Safety
/// `s` as in [`p2pc_core_save`]; `req`/`len` as in `input`. Not called
/// concurrently for the same session.
#[no_mangle]
pub unsafe extern "C" fn p2pc_core_round(s: *mut Session, req: *const u8, len: usize) -> *mut u8 {
    // SAFETY: guaranteed by the caller.
    let (s, req) = unsafe { (&mut *s, input(req, len)) };
    guarded(|| match serde_json::from_slice::<RoundIn>(req) {
        Ok(r) => json_buffer(&s.round(r)),
        Err(e) => json_buffer(&serde_json::json!({
            "ok": false, "error": format!("bad request: {e}"),
        })),
    })
}

/// What the UI shows (crate::api::Session::info), messages from `since`.
///
/// # Safety
/// `s` as in [`p2pc_core_save`].
#[no_mangle]
pub unsafe extern "C" fn p2pc_core_info(s: *mut Session, since: u64) -> *mut u8 {
    // SAFETY: guaranteed by the caller.
    let s = unsafe { &*s };
    guarded(|| json_buffer(&s.info(since as usize)))
}

/// # Safety
/// `s` must come from `p2pc_core_new`/`p2pc_core_restore`, closed once.
#[no_mangle]
pub unsafe extern "C" fn p2pc_core_close(s: *mut Session) {
    if !s.is_null() {
        // SAFETY: guaranteed by the caller.
        drop(unsafe { Box::from_raw(s) });
    }
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
