//! The DHT as the app gives it to the core (docs/V2_PLAN.md, option C:
//! "sans-IO"). The real Veilid DHT is asynchronous and driven from Dart, so
//! the core never touches the network: the host reads the values the core
//! asks for into a [`SnapshotDht`], runs the core on it, then performs the
//! writes the core produced, and repeats until the core needs nothing more.
//!
//! A value the host has not provided reads as `None`, exactly like a value
//! that has not propagated yet (F1): the protocol already waits for those,
//! so a round with missing data is safe, only incomplete.
//!
//! [`drive`] is the reference host loop, run in the tests against
//! [`MockDht`]; the Dart host does the same against Veilid.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::ops::RangeInclusive;

use crate::dht::{Dht, DhtError, MockDht, RecordId};
use crate::member::{Member, PocError};

/// A write the host has to perform: `value` into `record`/`subkey`, signed
/// with `writer` (the owner's or the slot's secret).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Write {
    pub record: RecordId,
    pub subkey: u32,
    pub value: Vec<u8>,
    pub writer: Vec<u8>,
}

#[derive(Default)]
pub struct SnapshotDht {
    now: u64,
    values: HashMap<(RecordId, u32), Option<Vec<u8>>>,
    records: VecDeque<(RecordId, Vec<u8>)>,
    rendezvous: VecDeque<(RecordId, Vec<u8>, Vec<u8>)>,
    needs: BTreeSet<(RecordId, u32)>,
    writes: Vec<Write>,
    used_records: u32,
    used_rendezvous: u32,
}

impl SnapshotDht {
    pub fn new(now: u64) -> Self {
        Self {
            now,
            ..Self::default()
        }
    }

    /// A value the host read (`None`: the subkey is empty on the network).
    pub fn provide(&mut self, record: &RecordId, subkey: u32, value: Option<Vec<u8>>) {
        self.values.insert((record.clone(), subkey), value);
    }

    /// An empty record the host created ahead of time, with its owner key.
    pub fn add_record(&mut self, record: RecordId, owner_secret: Vec<u8>) {
        self.records.push_back((record, owner_secret));
    }

    /// An empty rendezvous record (owner + one slot writer).
    pub fn add_rendezvous(&mut self, record: RecordId, owner: Vec<u8>, slot: Vec<u8>) {
        self.rendezvous.push_back((record, owner, slot));
    }

    /// Subkeys the core read without the host having provided them.
    pub fn needs(&self) -> Vec<(RecordId, u32)> {
        self.needs.iter().cloned().collect()
    }

    /// The writes produced, in order.
    pub fn writes(&self) -> &[Write] {
        &self.writes
    }

    /// How many of the provided records/rendezvous the core took.
    pub fn used(&self) -> (u32, u32) {
        (self.used_records, self.used_rendezvous)
    }
}

impl Dht for SnapshotDht {
    fn now(&self) -> u64 {
        self.now
    }

    fn get(&mut self, id: &RecordId, subkey: u32) -> Result<Option<Vec<u8>>, DhtError> {
        match self.values.get(&(id.clone(), subkey)) {
            Some(v) => Ok(v.clone()),
            None => {
                self.needs.insert((id.clone(), subkey));
                Ok(None)
            }
        }
    }

    fn set(
        &mut self,
        id: &RecordId,
        subkey: u32,
        value: &[u8],
        writer_secret: &[u8],
    ) -> Result<(), DhtError> {
        if value.len() > crate::dht::MAX_SUBKEY_BYTES {
            return Err(DhtError::TooLarge(value.len()));
        }
        // Later reads in the same round see it, as on the network.
        self.values
            .insert((id.clone(), subkey), Some(value.to_vec()));
        self.writes.push(Write {
            record: id.clone(),
            subkey,
            value: value.to_vec(),
            writer: writer_secret.to_vec(),
        });
        Ok(())
    }

    fn create(&mut self) -> Result<(RecordId, Vec<u8>), DhtError> {
        let r = self.records.pop_front().ok_or(DhtError::NeedRecords)?;
        self.used_records += 1;
        Ok(r)
    }

    fn create_rendezvous(
        &mut self,
        _slots: RangeInclusive<u32>,
    ) -> Result<(RecordId, Vec<u8>, Vec<u8>), DhtError> {
        let r = self.rendezvous.pop_front().ok_or(DhtError::NeedRecords)?;
        self.used_rendezvous += 1;
        Ok(r)
    }
}

/// Records the host keeps ready for operations that create some (create a
/// group, a removal's new generation, a takeover, a member's new outbox).
pub const RECORD_POOL: usize = 3;
pub const RENDEZVOUS_POOL: usize = 1;

/// The reference host: runs `op` on `member` the way the app will.
///
/// 1. Dry run on a copy of the member (its saved state restored), with the
///    values read so far, to learn what it reads; read those; repeat until
///    it asks for nothing new. (A dry run may write or create; that is
///    thrown away with the copy.)
/// 2. The real run, once, with everything it needs, and its writes
///    performed. So an operation with side effects (sending, committing)
///    never runs twice.
pub fn drive<T>(
    member: &mut Member,
    host: &mut MockDht,
    mut op: impl FnMut(&mut Member, &mut dyn Dht) -> Result<T, PocError>,
) -> Result<T, PocError> {
    let mut known: BTreeSet<(RecordId, u32)> = BTreeSet::new();
    let mut pool: Vec<(RecordId, Vec<u8>)> = vec![];
    let mut rv_pool: Vec<(RecordId, Vec<u8>, Vec<u8>)> = vec![];
    let fill = |host: &mut MockDht,
                pool: &mut Vec<(RecordId, Vec<u8>)>,
                rv_pool: &mut Vec<(RecordId, Vec<u8>, Vec<u8>)>|
     -> Result<(), PocError> {
        while pool.len() < RECORD_POOL {
            pool.push(Dht::create(host)?);
        }
        while rv_pool.len() < RENDEZVOUS_POOL {
            rv_pool.push(host.create_rendezvous(1..=4)?);
        }
        Ok(())
    };
    let snapshot = |host: &mut MockDht,
                    known: &BTreeSet<(RecordId, u32)>,
                    pool: &[(RecordId, Vec<u8>)],
                    rv_pool: &[(RecordId, Vec<u8>, Vec<u8>)]|
     -> Result<SnapshotDht, PocError> {
        let mut snap = SnapshotDht::new(host.now);
        for (r, k) in known {
            snap.provide(r, *k, MockDht::get(host, r, *k)?);
        }
        for (r, o) in pool {
            snap.add_record(r.clone(), o.clone());
        }
        for (r, o, s) in rv_pool {
            snap.add_rendezvous(r.clone(), o.clone(), s.clone());
        }
        Ok(snap)
    };

    // 1. Dry runs until the reads settle.
    for _ in 0..32 {
        fill(host, &mut pool, &mut rv_pool)?;
        let mut copy = Member::restore(&member.snapshot())?;
        let mut snap = snapshot(host, &known, &pool, &rv_pool)?;
        let _ = op(&mut copy, &mut snap);
        let new: Vec<_> = snap
            .needs()
            .into_iter()
            .filter(|k| !known.contains(k))
            .collect();
        if new.is_empty() {
            break;
        }
        known.extend(new);
    }

    // 2. The real run.
    fill(host, &mut pool, &mut rv_pool)?;
    let mut snap = snapshot(host, &known, &pool, &rv_pool)?;
    let result = op(member, &mut snap);
    for w in snap.writes() {
        host.set(&w.record, w.subkey, &w.value, &w.writer)?;
    }
    result
}
