//! What goes into DHT subkeys: the control record header (hash-chained,
//! docs/PROTOCOL.md B3/B5.2), and messages split into ≤32 KiB chunks
//! (F17). Every decoder returns an error on bad input and never panics
//! (F18).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::dht::MAX_SUBKEY_BYTES;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum WireError {
    #[error("malformed {0}")]
    Malformed(&'static str),
}

/// Subkey 0 of a control record `C_g`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlHeader {
    pub v: u8,
    pub gen: u64,
    pub epoch: u64,
    /// Subkeys used by the log (1..=log_count).
    pub log_count: u32,
    /// Hash of the previous header; empty for the first.
    pub prev: String,
}

impl ControlHeader {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("header serializes")
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let h: Self =
            serde_json::from_slice(bytes).map_err(|_| WireError::Malformed("control header"))?;
        if h.v != 2 || h.prev.len() > 64 {
            return Err(WireError::Malformed("control header"));
        }
        Ok(h)
    }

    pub fn hash(&self) -> String {
        hex(&Sha256::digest(self.encode()))
    }
}

/// Subkey 0 of a member outbox: only a count (no name, no profile key).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutboxHead {
    pub count: u32,
}

impl OutboxHead {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("head serializes")
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let h: Self =
            serde_json::from_slice(bytes).map_err(|_| WireError::Malformed("outbox head"))?;
        if h.count > 1_000_000 {
            return Err(WireError::Malformed("outbox head"));
        }
        Ok(h)
    }
}

/// What a log or outbox entry carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// An MLS message (commit, proposal or application message).
    Mls = 1,
    /// An MLS Welcome (rendezvous only).
    Welcome = 2,
    /// A KeyPackage (rendezvous only).
    KeyPackage = 3,
}

impl Kind {
    fn from_u8(b: u8) -> Option<Self> {
        match b {
            1 => Some(Kind::Mls),
            2 => Some(Kind::Welcome),
            3 => Some(Kind::KeyPackage),
            _ => None,
        }
    }
}

const MAGIC: [u8; 2] = *b"P2";
/// magic(2) kind(1) total(2) index(2)
const CHUNK_HEADER: usize = 7;
pub const CHUNK_PAYLOAD: usize = MAX_SUBKEY_BYTES - CHUNK_HEADER;
const MAX_CHUNKS: u16 = 64; // 2 MiB per message, far above any real one

/// Splits a message over as many subkey values as it needs.
pub fn chunk(kind: Kind, payload: &[u8]) -> Vec<Vec<u8>> {
    let parts: Vec<&[u8]> = if payload.is_empty() {
        vec![&[][..]]
    } else {
        payload.chunks(CHUNK_PAYLOAD).collect()
    };
    let total = parts.len() as u16;
    parts
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let mut v = Vec::with_capacity(CHUNK_HEADER + p.len());
            v.extend_from_slice(&MAGIC);
            v.push(kind as u8);
            v.extend_from_slice(&total.to_be_bytes());
            v.extend_from_slice(&(i as u16).to_be_bytes());
            v.extend_from_slice(p);
            v
        })
        .collect()
}

/// One chunk's header and payload.
#[derive(Debug, PartialEq, Eq)]
pub struct Chunk<'a> {
    pub kind: Kind,
    pub total: u16,
    pub index: u16,
    pub payload: &'a [u8],
}

pub fn parse_chunk(v: &[u8]) -> Result<Chunk<'_>, WireError> {
    if v.len() < CHUNK_HEADER || v[0..2] != MAGIC {
        return Err(WireError::Malformed("chunk"));
    }
    let kind = Kind::from_u8(v[2]).ok_or(WireError::Malformed("chunk kind"))?;
    let total = u16::from_be_bytes([v[3], v[4]]);
    let index = u16::from_be_bytes([v[5], v[6]]);
    if total == 0 || total > MAX_CHUNKS || index >= total {
        return Err(WireError::Malformed("chunk numbering"));
    }
    Ok(Chunk {
        kind,
        total,
        index,
        payload: &v[CHUNK_HEADER..],
    })
}

/// Reassembles a message from consecutive chunk values, which must be
/// complete and in order (index 0..total of one kind).
pub fn reassemble(values: &[Vec<u8>]) -> Result<(Kind, Vec<u8>), WireError> {
    let first = parse_chunk(values.first().ok_or(WireError::Malformed("empty"))?)?;
    if values.len() != first.total as usize {
        return Err(WireError::Malformed("chunk count"));
    }
    let mut out = Vec::new();
    for (i, v) in values.iter().enumerate() {
        let c = parse_chunk(v)?;
        if c.kind != first.kind || c.total != first.total || c.index as usize != i {
            return Err(WireError::Malformed("chunk order"));
        }
        out.extend_from_slice(c.payload);
    }
    Ok((first.kind, out))
}

/// The control-log state a sender has accepted (B8 `ctl`, B5.2 rule 6).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ctl {
    pub gen: u64,
    pub log_count: u32,
    pub log_hash: String,
}

/// Application payload inside an MLS application message (docs/PROTOCOL.md
/// B8, reduced to what the PoC needs).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum AppMsg {
    Text {
        id: String,
        seq: u64,
        text: String,
        /// Hash of this sender's previous message ("" for the first).
        prev: String,
        ctl: Ctl,
    },
    /// Admin, in the control log: where everyone's outbox is, who succeeds
    /// the admin (keyed by CIK hex).
    Directory {
        gen: u64,
        outboxes: Vec<(String, String)>,
        successors: Vec<String>,
    },
    /// Admin, in `C_g` after a removal or handover: the group continues in
    /// generation `gen` at record `control`.
    Move { gen: u64, control: String },
    /// Member, as the last message in its old outbox: its new outbox.
    MyOutbox { gen: u64, outbox: String },
    /// First successor, in its own outbox: it takes over as admin.
    Takeover { gen: u64, control: String },
}

impl AppMsg {
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("app message serializes")
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        serde_json::from_slice(bytes).map_err(|_| WireError::Malformed("app message"))
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}
