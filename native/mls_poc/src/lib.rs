//! p2p.communicator v2 proof of concept (docs/PROTOCOL.md B13).
//!
//! OpenMLS groups (ciphersuite 0x0003) whose commits are sequenced by one
//! admin through a control record, over an in-memory mock of the Veilid DHT
//! with injectable failures. Nothing here is used by the app yet.

pub mod bench;
pub mod dht;
pub mod ffi;
pub mod member;
pub mod provider;
pub mod scenario;
pub mod snapshot;
pub mod wire;
