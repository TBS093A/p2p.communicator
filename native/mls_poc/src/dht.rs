//! In-memory stand-in for the Veilid DHT (docs/PROTOCOL.md B13).
//!
//! Like Veilid: records with numbered subkeys, values of at most 32 KiB, and
//! writes only by the holder of the record's (or a subkey's) writer secret.
//! Unlike Veilid it is deterministic, with knobs for the failure scenarios:
//! propagation delay (F1), lost writes (F16) and storage nodes serving an
//! older value (F5).

use std::collections::{HashMap, HashSet};

use sha2::{Digest, Sha256};

/// Veilid's subkey value limit.
pub const MAX_SUBKEY_BYTES: usize = 32 * 1024;

pub type RecordId = String;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum DhtError {
    #[error("no such record")]
    NoRecord,
    #[error("not the writer of this subkey")]
    NotWriter,
    #[error("value of {0} bytes exceeds the 32 KiB subkey limit")]
    TooLarge(usize),
}

struct Version {
    visible_at: u64,
    value: Vec<u8>,
}

struct Record {
    owner: [u8; 32],
    /// Subkeys writable by someone else (the SMPL rendezvous slot).
    subkey_writers: HashMap<u32, [u8; 32]>,
    /// Every value ever written, oldest first.
    subkeys: HashMap<u32, Vec<Version>>,
}

fn hash(secret: &[u8]) -> [u8; 32] {
    Sha256::digest(secret).into()
}

#[derive(Default)]
pub struct MockDht {
    records: HashMap<RecordId, Record>,
    next_id: u64,
    /// Logical clock (ticks), advanced by tests.
    pub now: u64,
    /// Ticks before a write becomes visible to readers.
    delay: u64,
    /// Writes to these (record, subkey) are dropped this many times.
    lose: HashMap<(RecordId, u32), u32>,
    /// Records whose reads return the previous value (stale node).
    stale: HashSet<RecordId>,
    /// Counters for the report.
    pub writes: u64,
    pub bytes_written: u64,
    pub largest_value: usize,
}

impl MockDht {
    pub fn new() -> Self {
        Self::default()
    }

    /// New record owned by `owner_secret` (a member's fresh random key).
    pub fn create(&mut self, owner_secret: &[u8]) -> RecordId {
        self.next_id += 1;
        let id = format!("rec{:04}", self.next_id);
        self.records.insert(
            id.clone(),
            Record {
                owner: hash(owner_secret),
                subkey_writers: HashMap::new(),
                subkeys: HashMap::new(),
            },
        );
        id
    }

    /// Lets `writer_secret` write one subkey (SMPL member slot).
    pub fn allow_subkey_writer(
        &mut self,
        id: &RecordId,
        owner_secret: &[u8],
        subkey: u32,
        writer_secret: &[u8],
    ) -> Result<(), DhtError> {
        let rec = self.records.get_mut(id).ok_or(DhtError::NoRecord)?;
        if rec.owner != hash(owner_secret) {
            return Err(DhtError::NotWriter);
        }
        rec.subkey_writers.insert(subkey, hash(writer_secret));
        Ok(())
    }

    pub fn set(
        &mut self,
        id: &RecordId,
        subkey: u32,
        value: &[u8],
        writer_secret: &[u8],
    ) -> Result<(), DhtError> {
        if value.len() > MAX_SUBKEY_BYTES {
            return Err(DhtError::TooLarge(value.len()));
        }
        let now = self.now;
        let delay = self.delay;
        let rec = self.records.get_mut(id).ok_or(DhtError::NoRecord)?;
        let w = hash(writer_secret);
        let allowed = rec.owner == w || rec.subkey_writers.get(&subkey) == Some(&w);
        if !allowed {
            return Err(DhtError::NotWriter);
        }
        // The writer believes the write succeeded; the network lost it.
        if let Some(n) = self.lose.get_mut(&(id.clone(), subkey)) {
            if *n > 0 {
                *n -= 1;
                return Ok(());
            }
        }
        self.writes += 1;
        self.bytes_written += value.len() as u64;
        self.largest_value = self.largest_value.max(value.len());
        rec.subkeys.entry(subkey).or_default().push(Version {
            visible_at: now + delay,
            value: value.to_vec(),
        });
        Ok(())
    }

    /// Latest visible value (or the one before it, from a stale node).
    pub fn get(&self, id: &RecordId, subkey: u32) -> Result<Option<Vec<u8>>, DhtError> {
        let rec = self.records.get(id).ok_or(DhtError::NoRecord)?;
        let Some(versions) = rec.subkeys.get(&subkey) else {
            return Ok(None);
        };
        let visible: Vec<&Version> = versions
            .iter()
            .filter(|v| v.visible_at <= self.now)
            .collect();
        let pick = if self.stale.contains(id) && visible.len() >= 2 {
            visible.get(visible.len() - 2)
        } else {
            visible.last()
        };
        Ok(pick.map(|v| v.value.clone()))
    }

    // ------------------------------------------------- failure injection

    pub fn tick(&mut self, ticks: u64) {
        self.now += ticks;
    }

    pub fn set_delay(&mut self, ticks: u64) {
        self.delay = ticks;
    }

    pub fn lose_next_writes(&mut self, id: &RecordId, subkey: u32, count: u32) {
        self.lose.insert((id.clone(), subkey), count);
    }

    /// A malicious storage node serving arbitrary bytes (F18). Bypasses the
    /// writer check, as a node could serve anything for an unsigned value
    /// (Veilid signs values; this models what slips past that or a buggy
    /// peer).
    pub fn inject(&mut self, id: &RecordId, subkey: u32, value: &[u8]) {
        let now = self.now;
        if let Some(rec) = self.records.get_mut(id) {
            rec.subkeys.entry(subkey).or_default().push(Version {
                visible_at: now,
                value: value.to_vec(),
            });
        }
    }

    pub fn set_stale(&mut self, id: &RecordId, stale: bool) {
        if stale {
            self.stale.insert(id.clone());
        } else {
            self.stale.remove(id);
        }
    }
}
