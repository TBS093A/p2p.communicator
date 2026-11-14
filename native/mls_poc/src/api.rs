//! The core's API for the app (docs/V2_PLAN.md, option C, phase 1c).
//!
//! A [`Session`] is one member of one conversation. The host (Dart, over
//! Veilid) drives every operation in **rounds** of JSON, the same loop as
//! [`crate::snapshot::drive`]:
//!
//! 1. Dry rounds (`commit: false`): the operation runs on a copy of the
//!    session with the values the host has read so far; the reply lists the
//!    subkeys it still `needs`. The host reads those and asks again, until
//!    nothing new is needed. Nothing changes in the session.
//! 2. One real round (`commit: true`) with all of them: the operation runs
//!    for real, the session changes, and the reply lists the `writes` the
//!    host must perform (in order) and how many of the provided empty
//!    records it used.
//!
//! Byte strings travel as lowercase hex. Record ids are the host's own
//! (Veilid record keys); writer secrets are opaque to the core.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::member::{Invite, Member, PocError};
use crate::snapshot::SnapshotDht;
use crate::wire;

/// One operation of the protocol, as named in the round request.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    /// Read everything new: commits, messages, moves, takeovers.
    Sync,
    CreateGroup,
    /// Admin: a one-time invite. Result: the `p2pc2.` invite string.
    CreateInvite,
    /// Joiner: request to join, after the admin's key was checked out of
    /// band (`verified_admin` is the CIK the user compared).
    RequestJoin {
        invite: String,
        verified_admin: String,
    },
    /// Admin: stage adding the joiner who wrote to this rendezvous.
    StageAdd {
        rendezvous: String,
    },
    /// Admin: stage committing the pending proposals (e.g. Updates).
    StageCommitProposals,
    /// Admin: stage removing a member (CIK hex); starts a new generation.
    StageRemove {
        cik: String,
    },
    /// Admin: publish whatever is staged (resumable, §B5.1).
    PublishPending,
    /// Joiner: pick up the Welcome. Result: whether it was there.
    CompleteJoin {
        invite: String,
    },
    SendText {
        text: String,
    },
    ProposeUpdate,
    /// Admin: the successor list (CIK hex, in order).
    SetSuccessors {
        successors: Vec<String>,
    },
    /// First successor: take over after T_successor. Result: whether it did.
    TryTakeover,
}

#[derive(Debug, Deserialize)]
pub struct ValueIn {
    pub record: String,
    pub subkey: u32,
    /// Hex; null when the subkey is empty on the network.
    pub value: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct RecordIn {
    pub record: String,
    pub owner: String,
}

#[derive(Debug, Deserialize)]
pub struct RendezvousIn {
    pub record: String,
    pub owner: String,
    pub slot: String,
}

#[derive(Debug, Deserialize)]
pub struct RoundIn {
    #[serde(flatten)]
    pub op: Op,
    #[serde(default)]
    pub now: u64,
    #[serde(default)]
    pub values: Vec<ValueIn>,
    /// Empty records the host created ahead of time (operations that need
    /// a new record take one; see `used_records` in the reply).
    #[serde(default)]
    pub record_pool: Vec<RecordIn>,
    /// Empty one-time rendezvous records (for invites).
    #[serde(default)]
    pub rendezvous_pool: Vec<RendezvousIn>,
    #[serde(default)]
    pub commit: bool,
}

#[derive(Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct WriteOut {
    pub record: String,
    pub subkey: u32,
    pub value: String,
    pub writer: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct RoundOut {
    pub ok: bool,
    pub error: Option<String>,
    /// Subkeys read without a value provided: read them and ask again.
    pub needs: Vec<(String, u32)>,
    /// Only on a committed round: what to write, in this order.
    pub writes: Vec<WriteOut>,
    pub used_records: u32,
    pub used_rendezvous: u32,
    /// The operation's result (see [`Op`]), on a committed round.
    pub result: Value,
}

pub struct Session {
    member: Member,
}

impl Session {
    pub fn new(name: &str) -> Self {
        Self {
            member: Member::new(name),
        }
    }

    /// The session's whole state (MLS group, keys, log position, inbox), to
    /// keep in the PIN vault. Must be saved after every committed round,
    /// before its writes are performed.
    pub fn save(&self) -> Vec<u8> {
        self.member.snapshot()
    }

    pub fn restore(bytes: &[u8]) -> Result<Self, PocError> {
        Ok(Self {
            member: Member::restore(bytes)?,
        })
    }

    /// One round (see the module docs).
    pub fn round(&mut self, req: RoundIn) -> RoundOut {
        let mut snap = SnapshotDht::new(req.now);
        for v in &req.values {
            let value = match &v.value {
                None => None,
                Some(h) => match unhex(h) {
                    Some(b) => Some(b),
                    None => return error("value is not hex"),
                },
            };
            snap.provide(&v.record, v.subkey, value);
        }
        for r in &req.record_pool {
            let Some(owner) = unhex(&r.owner) else {
                return error("owner is not hex");
            };
            snap.add_record(r.record.clone(), owner);
        }
        for r in &req.rendezvous_pool {
            let (Some(owner), Some(slot)) = (unhex(&r.owner), unhex(&r.slot)) else {
                return error("rendezvous keys are not hex");
            };
            snap.add_rendezvous(r.record.clone(), owner, slot);
        }

        if !req.commit {
            // A dry run on a copy: only what it reads matters.
            let mut copy = match Member::restore(&self.member.snapshot()) {
                Ok(c) => c,
                Err(e) => return error(&e.to_string()),
            };
            let _ = run(&mut copy, &req.op, &mut snap);
            return RoundOut {
                ok: true,
                needs: snap.needs(),
                ..RoundOut::default()
            };
        }

        let result = run(&mut self.member, &req.op, &mut snap);
        let (used_records, used_rendezvous) = snap.used();
        let writes = snap
            .writes()
            .iter()
            .map(|w| WriteOut {
                record: w.record.clone(),
                subkey: w.subkey,
                value: wire::hex(&w.value),
                writer: wire::hex(&w.writer),
            })
            .collect();
        match result {
            Ok(result) => RoundOut {
                ok: true,
                error: None,
                needs: snap.needs(),
                writes,
                used_records,
                used_rendezvous,
                result,
            },
            // Writes made before a failure are still returned: the protocol
            // writes only what it has persisted, so performing them is safe
            // and resuming continues from there (§B5.1).
            Err(e) => RoundOut {
                ok: false,
                error: Some(e.to_string()),
                needs: snap.needs(),
                writes,
                used_records,
                used_rendezvous,
                result: Value::Null,
            },
        }
    }

    /// What the UI shows: identity, group, members, messages from index
    /// `since` on, and warnings.
    pub fn info(&self, since: usize) -> Value {
        let st = &self.member.st;
        json!({
            "cik": st.cik,
            "admin": st.admin_cik,
            "is_admin": self.member.is_admin(),
            "epoch": st.epoch,
            "gen": st.gen,
            "members": self.member.members(),
            "successors": st.successors,
            "has_pending": st.pending.is_some(),
            "removed": st.removed,
            "fork_suspected": st.fork_suspected,
            "history_diverged": st.history_diverged,
            "inbox_len": st.inbox.len(),
            "inbox": st.inbox.iter().skip(since).map(|r| json!({
                "from": r.from, "text": r.text, "epoch": r.epoch,
            })).collect::<Vec<_>>(),
            "gaps": self.member.real_gaps(),
        })
    }
}

fn error(msg: &str) -> RoundOut {
    RoundOut {
        ok: false,
        error: Some(msg.to_string()),
        ..RoundOut::default()
    }
}

fn run(m: &mut Member, op: &Op, dht: &mut SnapshotDht) -> Result<Value, PocError> {
    Ok(match op {
        Op::Sync => {
            m.sync(dht)?;
            Value::Null
        }
        Op::CreateGroup => {
            m.create_group(dht)?;
            Value::Null
        }
        Op::CreateInvite => json!(m.create_invite(dht)?.encode()),
        Op::RequestJoin {
            invite,
            verified_admin,
        } => {
            let inv = Invite::decode(invite)?;
            m.request_join(dht, &inv, verified_admin)?;
            Value::Null
        }
        Op::StageAdd { rendezvous } => {
            m.stage_add(dht, rendezvous)?;
            Value::Null
        }
        Op::StageCommitProposals => {
            m.stage_commit_proposals()?;
            Value::Null
        }
        Op::StageRemove { cik } => {
            m.stage_remove(dht, cik)?;
            Value::Null
        }
        Op::PublishPending => {
            m.publish_pending(dht)?;
            Value::Null
        }
        Op::CompleteJoin { invite } => {
            let inv = Invite::decode(invite)?;
            json!(m.complete_join(dht, &inv)?)
        }
        Op::SendText { text } => json!(m.send_text(dht, text)?),
        Op::ProposeUpdate => {
            m.propose_update(dht)?;
            Value::Null
        }
        Op::SetSuccessors { successors } => {
            m.set_successors(successors.clone());
            Value::Null
        }
        Op::TryTakeover => json!(m.try_takeover(dht)?),
    })
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}
