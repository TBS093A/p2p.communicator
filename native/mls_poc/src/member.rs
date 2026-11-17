//! One participant of a v2 group (docs/PROTOCOL.md B3–B5): MLS state, the
//! control record it follows, its own outbox and the others' outboxes.
//!
//! The admin is a member that also owns the control record `C_g` and is the
//! only one whose commits are accepted (B5.1). Everything a member needs to
//! resume after a restart is in [`Member::snapshot`].

use std::collections::{BTreeMap, BTreeSet};

use openmls::prelude::{
    tls_codec::{Deserialize as _, Serialize as _},
    *,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::{
    random::OpenMlsRand, signatures::Signer as _, types::SignatureScheme, OpenMlsProvider,
};
use serde::{Deserialize, Serialize};

use crate::dht::{Dht, RecordId};
use crate::provider::PocProvider;
use crate::wire::{self, AppMsg, ControlHeader, Kind, OutboxHead};

/// MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519 (0x0003).
pub const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519;

/// Out-of-order tolerance per sender (B12 F6: 100 skipped keys).
pub const OUT_OF_ORDER: u32 = 100;

// Record size limits (PROTOCOL §B3.1): Veilid allows 32 KiB per subkey and
// 1 MiB per record.

/// Control log subkeys (1..=LOG_SUBKEYS); the log never wraps.
pub const LOG_SUBKEYS: u32 = 28;
/// Free log subkeys an admin keeps for the next commit, what follows it and
/// a `Move`; with fewer left the group moves to a new generation first.
pub const LOG_RESERVE: u32 = 6;
/// Members' proposals the admin takes for one commit; each is copied into
/// the log before it (§B5.1). Further ones are not taken: their senders
/// propose again after the next commit.
pub const MAX_COPIED: usize = 8;
/// Outbox ring: position `p` (1-based) lives in subkey `1 + (p-1) % R`.
pub const OUTBOX_RING: u32 = 200;
/// Largest application message plaintext (the 4096-byte padding bucket).
pub const MAX_PLAINTEXT: usize = 4096;
/// Rendezvous (Veilid SMPL: owner subkeys first): the admin's answer.
pub const ANSWER_FIRST: u32 = 0;
pub const ANSWER_SUBKEYS: u32 = 4;
/// Rendezvous: the joiner's request slot.
pub const REQUEST_FIRST: u32 = 4;
pub const REQUEST_SUBKEYS: u32 = 4;
/// Epochs whose secrets are kept for late messages (B12 F7: the previous
/// one). Time-based deletion (24 h) is done by [`Member::expire_past_epochs`].
pub const PAST_EPOCHS: usize = 1;

#[derive(Debug, thiserror::Error)]
pub enum PocError {
    #[error("{0}")]
    Rejected(String),
    #[error("dht: {0}")]
    Dht(#[from] crate::dht::DhtError),
    #[error("mls: {0}")]
    Mls(String),
}

fn mls<E: std::fmt::Debug>(e: E) -> PocError {
    PocError::Mls(format!("{e:?}"))
}

/// A one-time invite (B4): request access only, no read access.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Invite {
    pub rendezvous: RecordId,
    /// Writer secret of the request slot (subkeys 4..=7): opaque bytes (in
    /// the app, a Veilid key pair). Hex in the invite, so it stays short
    /// enough for a QR code.
    #[serde(with = "crate::wire::hex_bytes")]
    pub slot: Vec<u8>,
    /// Hex of the admin's conversation identity key.
    pub admin_cik: String,
}

impl Invite {
    pub fn encode(&self) -> String {
        format!(
            "p2pc2.{}",
            serde_json::to_string(self).expect("invite serializes")
        )
    }
    pub fn decode(s: &str) -> Result<Self, PocError> {
        let body = s
            .strip_prefix("p2pc2.")
            .ok_or_else(|| PocError::Rejected("not a v2 invite".into()))?;
        let inv: Invite = serde_json::from_str(body)
            .map_err(|_| PocError::Rejected("malformed invite".into()))?;
        if inv.slot.is_empty()
            || inv.slot.len() > 256
            || inv.admin_cik.len() != 64
            || inv.rendezvous.is_empty()
        {
            return Err(PocError::Rejected("malformed invite".into()));
        }
        Ok(inv)
    }
}

/// Join request written to the rendezvous slot.
#[derive(Serialize, Deserialize)]
struct JoinRequest {
    key_package: Vec<u8>,
    outbox: RecordId,
    /// DM started from a shared group (§B10): who the joiner is there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    proof: Option<DmProof>,
    /// The name the joiner chose, shown to the admin with the `CIK`
    /// fingerprint before approving (§B4 step 4).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

/// Longest joiner name accepted in a join request (characters).
pub const MAX_JOIN_NAME: usize = 64;

/// What the admin sees of a join request before approving it (§B4 step 4).
#[derive(Clone, Debug, Serialize)]
pub struct JoinRequestView {
    pub cik: String,
    pub name: String,
}

/// §B10: the joiner's `CIK` in the shared group and its signature over
/// (`"p2pc2-dm-join"`, rendezvous record key, the joiner's new `CIK`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DmProof {
    pub cik: String,
    pub sig: String,
}

/// What a DM join proof signs (§B10), with separators so no field can
/// shift into another.
fn dm_join_payload(rendezvous: &str, new_cik: &str) -> Vec<u8> {
    let mut p = b"p2pc2-dm-join".to_vec();
    p.push(0);
    p.extend_from_slice(rendezvous.as_bytes());
    p.push(0);
    p.extend_from_slice(new_cik.as_bytes());
    p
}

/// Welcome plus what the joiner needs to find the group, written by the
/// admin to the rendezvous record (subkeys 10..).
struct JoinAnswer {
    welcome: Vec<u8>,
    control: RecordId,
    gen: u64,
}

impl JoinAnswer {
    /// Binary, so a large Welcome stays its own size (JSON would write each
    /// byte as a number): `gen` (u64 BE), control id length (u16 BE), the
    /// id, then the Welcome.
    fn encode(&self) -> Vec<u8> {
        let id = self.control.as_bytes();
        let mut out = Vec::with_capacity(10 + id.len() + self.welcome.len());
        out.extend_from_slice(&self.gen.to_be_bytes());
        out.extend_from_slice(&(id.len() as u16).to_be_bytes());
        out.extend_from_slice(id);
        out.extend_from_slice(&self.welcome);
        out
    }

    fn decode(b: &[u8]) -> Option<Self> {
        let gen = u64::from_be_bytes(b.get(..8)?.try_into().ok()?);
        let n = u16::from_be_bytes(b.get(8..10)?.try_into().ok()?) as usize;
        let control = String::from_utf8(b.get(10..10 + n)?.to_vec()).ok()?;
        let welcome = b.get(10 + n..)?.to_vec();
        if welcome.is_empty() {
            return None;
        }
        Some(Self {
            welcome,
            control,
            gen,
        })
    }
}

/// A reader's position in one outbox: next subkey, and earlier subkeys that
/// were not readable yet (F1).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Cursor {
    pub next: u32,
    pub missing: BTreeSet<u32>,
}

/// One joiner of an Add commit.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Joiner {
    rendezvous: RecordId,
    rendezvous_owner: Vec<u8>,
    cik: String,
    outbox: RecordId,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum PendingKind {
    Add {
        welcome: Vec<u8>,
        joiners: Vec<Joiner>,
    },
    /// Removal: the group moves to `next_control` (B5.3).
    Remove {
        next_control: RecordId,
        next_owner: Vec<u8>,
    },
    /// Commit of pending proposals (Updates, F13).
    Proposals,
    /// Full control log: the group moves to `next_control` without a
    /// commit; only the `Move` is published (§B3.1, F20).
    Rotate {
        next_control: RecordId,
        next_owner: Vec<u8>,
    },
    /// Handover: no commit, only an `AdminTransfer` in the log (§B5.4).
    Handover { to: String },
}

/// A commit created and persisted, then published in phases that can each
/// be repeated after a restart with the same bytes at the same positions
/// (F9): 0 = write the commit, 1 = merge it and encrypt what follows it,
/// 2 = write that, the header, and finish.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Pending {
    pub kind: PendingKind,
    pub commit: Vec<u8>,
    /// Log position and hash before the commit.
    at: u32,
    hash_at: String,
    pub phase: u8,
    /// Encrypted once in phase 1, then only ever rewritten identically.
    followups: Vec<Vec<u8>>,
    /// Members' proposals the commit references, copied into the log right
    /// before it (§B5.1), as the senders' original MLS messages.
    #[serde(default)]
    pub proposals: Vec<Vec<u8>>,
}

/// Per-member move to a new generation (B5.3 table).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MoveState {
    Stable,
    Moving {
        gen: u64,
        control: RecordId,
    },
    Created {
        gen: u64,
        control: RecordId,
        outbox: RecordId,
        secret: Vec<u8>,
    },
    Announced {
        gen: u64,
        control: RecordId,
        since: u64,
    },
}

/// A message shown in the conversation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Received {
    pub from: String,
    pub text: String,
    pub epoch: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct State {
    pub name: String,
    pub cik: String,
    cik_public: Vec<u8>,
    group_id: Option<Vec<u8>>,
    pub admin_cik: String,
    pub successors: Vec<String>,
    // Followed control record and the last accepted header (B5.2).
    pub gen: u64,
    pub control: Option<RecordId>,
    pub epoch: u64,
    pub log_count: u32,
    pub log_hash: String,
    // Admin only.
    control_owner: Option<Vec<u8>>,
    pub pending: Option<Pending>,
    invites: BTreeMap<RecordId, Vec<u8>>,
    /// DM invites (§B10): rendezvous -> the `CIK` in the shared group whose
    /// signed proof a join request must carry (F25).
    #[serde(default)]
    invite_for: BTreeMap<RecordId, String>,
    // Own outbox.
    my_outbox: Option<(RecordId, Vec<u8>)>,
    my_count: u32,
    my_seq: u64,
    my_prev: String,
    /// Values written to my outbox, to re-send what the network lost (F16).
    sent: BTreeMap<u32, Vec<u8>>,
    // Others.
    pub outboxes: BTreeMap<String, RecordId>,
    cursors: BTreeMap<RecordId, Cursor>,
    pub moved_to: BTreeMap<String, (u64, RecordId)>,
    pub move_state: MoveState,
    /// Old outboxes still read during a move, per member CIK.
    old_outboxes: BTreeMap<String, RecordId>,
    pub last_admin_activity: u64,
    pub removed: bool,
    pub fork_suspected: bool,
    /// `logHash` after every accepted log position of the current
    /// generation, keyed "gen:count", to check peers' `ctl` (B5.2 r6).
    log_hashes: BTreeMap<String, String>,
    /// A peer accepted a different log for the same position: no further
    /// commits are accepted (B5.2 r6, F19).
    pub history_diverged: bool,
    pub inbox: Vec<Received>,
    /// Message hashes seen per sender, and `prev` hashes referenced but not
    /// seen yet: what stays here is a real gap (F6/F16).
    seen: BTreeSet<String>,
    pub awaiting: BTreeMap<String, BTreeSet<String>>,
    /// What was ignored or rejected, for the tests and the report.
    pub events: Vec<String>,
    pub undecryptable: u32,
    /// Messages a sender's outbox ring overwrote before we read them
    /// (§B3.1, F21): shown as a gap, never silently.
    #[serde(default)]
    pub lost_messages: u32,
    /// Admin: control-log values written to `log_written_for` and not yet
    /// read back from the network, to re-write if a storage node dropped
    /// them (F16), plus whether the header still has to be confirmed.
    #[serde(default)]
    log_written: BTreeMap<u32, Vec<u8>>,
    #[serde(default)]
    log_written_for: Option<RecordId>,
    #[serde(default)]
    header_unverified: bool,
    /// Admin: members' proposals taken from outboxes and stored, as
    /// (proposal reference, original MLS message), to copy into the log
    /// before the commit that references them (§B5.1, F23).
    #[serde(default)]
    proposal_copies: Vec<(Vec<u8>, Vec<u8>)>,
    /// Hashes of own proposals sent in this epoch: their copies in the log
    /// are skipped (MLS cannot decrypt a member's own message).
    #[serde(default)]
    my_proposals: BTreeSet<String>,
    /// Admin: a commit should follow soon even without proposals (after a
    /// handover or after proposals were dropped), so members holding their
    /// own unanswered proposals can send again.
    #[serde(default)]
    pub commit_due: bool,
    /// This member was handed the admin role and still has to start the
    /// next generation (§B5.4).
    #[serde(default)]
    pub handover_due: bool,
    /// `Takeover`s read from a member's outbox before the log's
    /// `AdminTransfer` that makes it the admin (outboxes are read first).
    #[serde(default)]
    early_takeovers: BTreeMap<String, (u64, RecordId)>,
}

/// The outbox ring subkey of position `p` (1-based).
fn ring_slot(p: u32) -> u32 {
    1 + (p - 1) % OUTBOX_RING
}

/// An outbox value carries its position, so a reader can tell a slot that
/// holds an older lap (not propagated yet) from one already overwritten.
fn with_position(p: u32, chunk: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(4 + chunk.len());
    v.extend_from_slice(&p.to_be_bytes());
    v.extend_from_slice(chunk);
    v
}

/// The chunk inside an outbox value, without its position.
pub fn outbox_payload(value: &[u8]) -> Option<&[u8]> {
    value.get(4..)
}

enum Slot {
    Value(Vec<u8>),
    /// Empty, or still an older lap: not propagated yet (F1).
    NotYet,
    /// A newer lap already: the ring overwrote it (F21).
    Overwritten,
    Malformed,
}

fn read_slot(dht: &mut dyn Dht, outbox: &RecordId, p: u32) -> Result<Slot, PocError> {
    let Some(v) = dht.get(outbox, ring_slot(p))? else {
        return Ok(Slot::NotYet);
    };
    let Some(pos) = v
        .get(..4)
        .and_then(|b| b.try_into().ok())
        .map(u32::from_be_bytes)
    else {
        return Ok(Slot::Malformed);
    };
    Ok(match pos.cmp(&p) {
        std::cmp::Ordering::Equal => Slot::Value(v[4..].to_vec()),
        std::cmp::Ordering::Less => Slot::NotYet,
        std::cmp::Ordering::Greater => Slot::Overwritten,
    })
}

pub struct Member {
    pub st: State,
    provider: PocProvider,
    signer: SignatureKeyPair,
    group: Option<MlsGroup>,
}

fn create_config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(CIPHERSUITE)
        .use_ratchet_tree_extension(true)
        .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .max_past_epochs(PAST_EPOCHS)
        .padding_size(256)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(OUT_OF_ORDER, 1000))
        .build()
}

fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .wire_format_policy(PURE_CIPHERTEXT_WIRE_FORMAT_POLICY)
        .max_past_epochs(PAST_EPOCHS)
        .padding_size(256)
        .sender_ratchet_configuration(SenderRatchetConfiguration::new(OUT_OF_ORDER, 1000))
        .build()
}

impl Member {
    /// A fresh identity for one conversation (B2: CIK, random, unlinkable).
    pub fn new(name: &str) -> Self {
        let provider = PocProvider::default();
        let signer = SignatureKeyPair::new(SignatureScheme::ED25519).expect("ed25519 keygen");
        signer.store(provider.storage()).expect("store signer");
        let cik = wire::hex(signer.public());
        Self {
            st: State {
                name: name.into(),
                cik,
                cik_public: signer.public().to_vec(),
                group_id: None,
                admin_cik: String::new(),
                successors: vec![],
                gen: 0,
                control: None,
                epoch: 0,
                log_count: 0,
                log_hash: String::new(),
                control_owner: None,
                pending: None,
                invites: BTreeMap::new(),
                invite_for: BTreeMap::new(),
                my_outbox: None,
                my_count: 0,
                my_seq: 0,
                my_prev: String::new(),
                sent: BTreeMap::new(),
                outboxes: BTreeMap::new(),
                cursors: BTreeMap::new(),
                moved_to: BTreeMap::new(),
                move_state: MoveState::Stable,
                old_outboxes: BTreeMap::new(),
                last_admin_activity: 0,
                removed: false,
                fork_suspected: false,
                log_hashes: BTreeMap::new(),
                history_diverged: false,
                inbox: vec![],
                seen: BTreeSet::new(),
                awaiting: BTreeMap::new(),
                events: vec![],
                undecryptable: 0,
                lost_messages: 0,
                log_written: BTreeMap::new(),
                log_written_for: None,
                header_unverified: false,
                proposal_copies: vec![],
                my_proposals: BTreeSet::new(),
                commit_due: false,
                handover_due: false,
                early_takeovers: BTreeMap::new(),
            },
            provider,
            signer,
            group: None,
        }
    }

    fn credential(&self) -> CredentialWithKey {
        CredentialWithKey {
            // Only the CIK: names travel inside E2EE messages (B8).
            credential: BasicCredential::new(self.st.cik.clone().into_bytes()).into(),
            signature_key: self.signer.public().into(),
        }
    }

    fn random(&self, n: usize) -> Vec<u8> {
        self.provider.rand().random_vec(n).expect("rng")
    }

    pub fn group(&self) -> Option<&MlsGroup> {
        self.group.as_ref()
    }

    pub fn is_admin(&self) -> bool {
        self.st.admin_cik == self.st.cik
    }

    pub fn members(&self) -> Vec<String> {
        self.group
            .as_ref()
            .map(|g| g.members().map(|m| wire::hex(&m.signature_key)).collect())
            .unwrap_or_default()
    }

    /// Proposals (e.g. members' Updates) read and not committed yet.
    pub fn pending_proposals(&self) -> usize {
        self.group
            .as_ref()
            .map(|g| g.pending_proposals().count())
            .unwrap_or(0)
    }

    /// Whether this member's own proposal (an Update) waits for a commit:
    /// MLS sends no application message until then.
    pub fn my_update_pending(&self) -> bool {
        self.group.as_ref().is_some_and(|g| {
            let me = g.own_leaf_index();
            g.pending_proposals()
                .any(|q| matches!(q.sender(), Sender::Member(i) if *i == me))
        })
    }

    /// Admin: copies of the stored proposals, for the next commit.
    fn copies_for_commit(&self) -> Vec<Vec<u8>> {
        let Some(group) = self.group.as_ref() else {
            return vec![];
        };
        self.st
            .proposal_copies
            .iter()
            .filter(|(r, _)| {
                group
                    .pending_proposals()
                    .any(|q| q.proposal_reference_ref().as_slice() == r.as_slice())
            })
            .map(|(_, m)| m.clone())
            .collect()
    }

    fn chunks_of(msgs: &[Vec<u8>]) -> u32 {
        msgs.iter()
            .map(|m| wire::chunk(Kind::Mls, m).len() as u32)
            .sum()
    }

    /// After any merged commit: the proposals of the old epoch are gone.
    fn epoch_changed(&mut self) {
        self.st.proposal_copies.clear();
        self.st.my_proposals.clear();
        self.st.commit_due = false;
    }

    pub fn epoch_authenticator(&self) -> Vec<u8> {
        self.group
            .as_ref()
            .map(|g| g.epoch_authenticator().as_slice().to_vec())
            .unwrap_or_default()
    }

    // ------------------------------------------------------- persistence

    /// Everything needed to resume: app state plus OpenMLS storage. In the
    /// app this is written to the PIN vault before any dependent message is
    /// published (B7).
    pub fn snapshot(&self) -> Vec<u8> {
        serde_json::to_vec(&(&self.st, self.provider.snapshot())).expect("snapshot serializes")
    }

    pub fn restore(bytes: &[u8]) -> Result<Self, PocError> {
        let (st, storage): (State, Vec<u8>) =
            serde_json::from_slice(bytes).map_err(|_| PocError::Rejected("bad snapshot".into()))?;
        let provider = PocProvider::restore(&storage).map_err(mls)?;
        let signer =
            SignatureKeyPair::read(provider.storage(), &st.cik_public, SignatureScheme::ED25519)
                .ok_or_else(|| PocError::Rejected("signer missing from snapshot".into()))?;
        let group = match &st.group_id {
            Some(id) => {
                MlsGroup::load(provider.storage(), &GroupId::from_slice(id)).map_err(mls)?
            }
            None => None,
        };
        Ok(Self {
            st,
            provider,
            signer,
            group,
        })
    }

    // ------------------------------------------------------ group set-up

    /// The admin creates the group, its control record and own outbox.
    pub fn create_group(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        // Records first: if the host has none ready, nothing has changed.
        let (control, owner) = dht.create()?;
        let (outbox, secret) = self.new_outbox(dht)?;
        let group = MlsGroup::new(
            &self.provider,
            &self.signer,
            &create_config(),
            self.credential(),
        )
        .map_err(mls)?;
        self.st.group_id = Some(group.group_id().as_slice().to_vec());
        self.group = Some(group);
        self.st.admin_cik = self.st.cik.clone();
        self.st.last_admin_activity = dht.now();
        self.st.control_owner = Some(owner);
        self.st.control = Some(control);
        self.write_header(dht)?;
        self.st.my_outbox = Some((outbox.clone(), secret));
        let me = self.st.cik.clone();
        self.st.outboxes.insert(me, outbox);
        Ok(())
    }

    fn new_outbox(&self, dht: &mut dyn Dht) -> Result<(RecordId, Vec<u8>), PocError> {
        let (id, secret) = dht.create()?;
        dht.set(&id, 0, &OutboxHead { count: 0 }.encode(), &secret)?;
        Ok((id, secret))
    }

    /// Admin: the successor list members will accept a takeover from.
    pub fn set_successors(&mut self, successors: Vec<String>) {
        self.st.successors = successors;
    }

    /// Admin: a one-time invite with its own rendezvous record.
    pub fn create_invite(&mut self, dht: &mut dyn Dht) -> Result<Invite, PocError> {
        self.create_invite_for(dht, None)
    }

    /// Admin: a one-time invite; with `for_cik` (a DM started from a
    /// shared group, §B10) only a join request proven by that `CIK` in the
    /// shared group is admitted (F25).
    pub fn create_invite_for(
        &mut self,
        dht: &mut dyn Dht,
        for_cik: Option<&str>,
    ) -> Result<Invite, PocError> {
        if for_cik.is_some_and(|c| c.len() != 64 || wire::unhex_opt(c).is_none()) {
            return Err(PocError::Rejected("not a member key".into()));
        }
        let (rendezvous, owner, slot) =
            dht.create_rendezvous(REQUEST_FIRST..=REQUEST_FIRST + REQUEST_SUBKEYS - 1)?;
        self.st.invites.insert(rendezvous.clone(), owner);
        if let Some(c) = for_cik {
            self.st.invite_for.insert(rendezvous.clone(), c.to_string());
        }
        Ok(Invite {
            rendezvous,
            slot,
            admin_cik: self.st.cik.clone(),
        })
    }

    /// In the shared group: signs that the new identity `new_cik` asking to
    /// join through `rendezvous` is this member (§B10).
    pub fn sign_dm_join(&self, rendezvous: &str, new_cik: &str) -> Result<DmProof, PocError> {
        let sig = self
            .signer
            .sign(&dm_join_payload(rendezvous, new_cik))
            .map_err(mls)?;
        Ok(DmProof {
            cik: self.st.cik.clone(),
            sig: wire::hex(&sig),
        })
    }

    /// Joiner: writes a KeyPackage to the invite's slot. `verified_admin`
    /// is the admin CIK compared out of band (B4 step 2); without a match no
    /// request is sent.
    pub fn request_join(
        &mut self,
        dht: &mut dyn Dht,
        invite: &Invite,
        verified_admin: &str,
    ) -> Result<usize, PocError> {
        self.request_join_with(dht, invite, verified_admin, None)
    }

    /// Like [`Member::request_join`], with a DM proof (§B10).
    pub fn request_join_with(
        &mut self,
        dht: &mut dyn Dht,
        invite: &Invite,
        verified_admin: &str,
        proof: Option<DmProof>,
    ) -> Result<usize, PocError> {
        self.request_join_named(dht, invite, verified_admin, proof, None)
    }

    /// Like [`Member::request_join_with`], with the name the admin is shown
    /// next to our `CIK` fingerprint (§B4 step 4).
    pub fn request_join_named(
        &mut self,
        dht: &mut dyn Dht,
        invite: &Invite,
        verified_admin: &str,
        proof: Option<DmProof>,
        name: Option<&str>,
    ) -> Result<usize, PocError> {
        if verified_admin != invite.admin_cik {
            return Err(PocError::Rejected(
                "admin key not verified out of band: no join request sent".into(),
            ));
        }
        let name = name.map(str::trim).filter(|n| !n.is_empty());
        if name.is_some_and(|n| n.chars().count() > MAX_JOIN_NAME) {
            return Err(PocError::Rejected("name too long".into()));
        }
        let kp = KeyPackage::builder()
            .build(CIPHERSUITE, &self.provider, &self.signer, self.credential())
            .map_err(mls)?;
        let kp_bytes = kp.key_package().tls_serialize_detached().map_err(mls)?;
        let (outbox, secret) = self.new_outbox(dht)?;
        self.st.my_outbox = Some((outbox.clone(), secret));
        // PoC simplification: the request is not HPKE-sealed to the admin's
        // CIK here (the KeyPackage is public data; sealing hides metadata).
        let req = serde_json::to_vec(&JoinRequest {
            key_package: kp_bytes.clone(),
            outbox,
            proof,
            name: name.map(str::to_string),
        })
        .expect("request serializes");
        let chunks = wire::chunk(Kind::KeyPackage, &req);
        if chunks.len() > REQUEST_SUBKEYS as usize {
            return Err(PocError::Rejected("join request too large".into()));
        }
        for (i, c) in chunks.iter().enumerate() {
            dht.set(
                &invite.rendezvous,
                REQUEST_FIRST + i as u32,
                c,
                &invite.slot,
            )?;
        }
        Ok(kp_bytes.len())
    }

    /// Admin: stages the Add for a pending join request (does not publish).
    pub fn stage_add(&mut self, dht: &mut dyn Dht, rendezvous: &RecordId) -> Result<(), PocError> {
        self.stage_add_many(dht, std::slice::from_ref(rendezvous))
    }

    /// Admin: the join request waiting at `rendezvous`, to show before
    /// approving it (§B4 step 4); None while there is none (or it is still
    /// propagating). A malformed or refused request is an error.
    pub fn peek_join(
        &self,
        dht: &mut dyn Dht,
        rendezvous: &RecordId,
    ) -> Result<Option<JoinRequestView>, PocError> {
        match self.read_join_request(dht, rendezvous) {
            Ok((_, joiner, name)) => Ok(Some(JoinRequestView {
                cik: joiner.cik,
                name,
            })),
            Err(PocError::Rejected(m))
                if m == "no join request yet" || m == "join request incomplete" =>
            {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }

    /// Admin: stages the Add the admin approved: only if the request at
    /// `rendezvous` is still the one shown, from `cik` (anyone holding the
    /// invite can rewrite the request slot in between).
    pub fn stage_add_approved(
        &mut self,
        dht: &mut dyn Dht,
        rendezvous: &RecordId,
        cik: &str,
    ) -> Result<(), PocError> {
        let (_, joiner, _) = self.read_join_request(dht, rendezvous)?;
        if joiner.cik != cik {
            return Err(PocError::Rejected(
                "join request changed since it was shown".into(),
            ));
        }
        self.stage_add(dht, rendezvous)
    }

    /// Admin: one Add commit for several join requests (F17: one Welcome
    /// for many members).
    pub fn stage_add_many(
        &mut self,
        dht: &mut dyn Dht,
        rendezvous: &[RecordId],
    ) -> Result<(), PocError> {
        self.require_no_pending()?;
        let proposals = self.copies_for_commit();
        let mut kps = vec![];
        let mut joiners = vec![];
        for r in rendezvous {
            let (kp, joiner, _) = self.read_join_request(dht, r)?;
            kps.push(kp);
            joiners.push(joiner);
        }
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        let (commit, welcome, _) = group
            .add_members(&self.provider, &self.signer, &kps)
            .map_err(mls)?;
        let welcome = welcome.to_bytes().map_err(mls)?;
        // The answer must fit the rendezvous' answer subkeys (§B3.1): too
        // many joiners at once are refused before anything is published.
        let answer = JoinAnswer {
            welcome: welcome.clone(),
            control: self.st.control.clone().unwrap_or_default(),
            gen: self.st.gen,
        }
        .encode();
        let answer_len = wire::chunk(Kind::Welcome, &answer).len();
        if answer_len > ANSWER_SUBKEYS as usize {
            group
                .clear_pending_commit(self.provider.storage())
                .map_err(mls)?;
            return Err(PocError::Rejected("too many joiners at once".into()));
        }
        self.st.pending = Some(Pending {
            kind: PendingKind::Add { welcome, joiners },
            commit: commit.to_bytes().map_err(mls)?,
            at: self.st.log_count,
            hash_at: self.st.log_hash.clone(),
            phase: 0,
            followups: vec![],
            proposals,
        });
        Ok(())
    }

    fn read_join_request(
        &self,
        dht: &mut dyn Dht,
        rendezvous: &RecordId,
    ) -> Result<(KeyPackage, Joiner, String), PocError> {
        let owner = self
            .st
            .invites
            .get(rendezvous)
            .cloned()
            .ok_or_else(|| PocError::Rejected("unknown or used invite".into()))?;
        let mut values = vec![];
        let first = dht
            .get(rendezvous, REQUEST_FIRST)?
            .ok_or_else(|| PocError::Rejected("no join request yet".into()))?;
        let total = wire::parse_chunk(&first)
            .map_err(|e| PocError::Rejected(e.to_string()))?
            .total as u32;
        if total == 0 || total > REQUEST_SUBKEYS {
            return Err(PocError::Rejected("malformed join request".into()));
        }
        values.push(first);
        for k in REQUEST_FIRST + 1..REQUEST_FIRST + total {
            values.push(
                dht.get(rendezvous, k)?
                    .ok_or_else(|| PocError::Rejected("join request incomplete".into()))?,
            );
        }
        let (kind, body) =
            wire::reassemble(&values).map_err(|e| PocError::Rejected(e.to_string()))?;
        if kind != Kind::KeyPackage {
            return Err(PocError::Rejected("not a join request".into()));
        }
        let req: JoinRequest = serde_json::from_slice(&body)
            .map_err(|_| PocError::Rejected("malformed join request".into()))?;
        let kp = KeyPackageIn::tls_deserialize_exact(req.key_package.as_slice())
            .map_err(mls)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(mls)?;
        let joiner_cik = wire::hex(kp.leaf_node().signature_key().as_slice());
        // The credential names exactly the key that signs (no borrowed ids).
        if kp.leaf_node().credential().serialized_content() != joiner_cik.as_bytes() {
            return Err(PocError::Rejected(
                "credential does not match its key".into(),
            ));
        }
        // §B10, F25: a DM invite admits only the member it was meant for.
        if let Some(expected) = self.st.invite_for.get(rendezvous) {
            let ok = req.proof.as_ref().is_some_and(|p| {
                p.cik == *expected
                    && match (wire::unhex_opt(&p.cik), wire::unhex_opt(&p.sig)) {
                        (Some(pk), Some(sig)) => self
                            .provider
                            .crypto()
                            .verify_signature(
                                SignatureScheme::ED25519,
                                &dm_join_payload(rendezvous, &joiner_cik),
                                &pk,
                                &sig,
                            )
                            .is_ok(),
                        _ => false,
                    }
            });
            if !ok {
                return Err(PocError::Rejected(
                    "join request not from the invited member".into(),
                ));
            }
        }
        Ok((
            kp,
            Joiner {
                rendezvous: rendezvous.clone(),
                rendezvous_owner: owner,
                cik: joiner_cik,
                outbox: req.outbox,
            },
            // Shown to the admin only: trimmed and cut to the limit.
            req.name
                .unwrap_or_default()
                .trim()
                .chars()
                .filter(|c| !c.is_control())
                .take(MAX_JOIN_NAME)
                .collect(),
        ))
    }

    fn require_no_pending(&self) -> Result<(), PocError> {
        if self.st.pending.is_some() {
            return Err(PocError::Rejected(
                "a commit is pending: publish it first".into(),
            ));
        }
        if !self.is_admin() {
            return Err(PocError::Rejected("only the admin commits".into()));
        }
        // §B3.1, F20: with too little log left, the group moves to a new
        // generation first (stage_rotate), so a commit never half-fits.
        if self.needs_rotation() {
            return Err(PocError::Rejected(
                "control log full: rotate to a new generation first".into(),
            ));
        }
        Ok(())
    }

    /// Admin: stages the removal of `cik` and a move to a new generation.
    pub fn stage_remove(&mut self, dht: &mut dyn Dht, cik: &str) -> Result<(), PocError> {
        self.require_no_pending()?;
        let group = self
            .group
            .as_ref()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        let leaf = group
            .members()
            .find(|m| wire::hex(&m.signature_key) == cik)
            .map(|m| m.index)
            .ok_or_else(|| PocError::Rejected("not a member".into()))?;
        // 1. New control record first (B5.3 step 1).
        let (next_control, next_owner) = dht.create()?;
        let gen = self.st.gen + 1;
        let header = ControlHeader {
            v: 2,
            gen,
            epoch: self.st.epoch,
            log_count: 0,
            prev: String::new(),
        };
        dht.set(&next_control, 0, &header.encode(), &next_owner)?;
        // 2. Commit created and persisted before publishing.
        let proposals = self.copies_for_commit();
        let group = self.group.as_mut().expect("checked above");
        let (commit, _, _) = group
            .remove_members(&self.provider, &self.signer, &[leaf])
            .map_err(mls)?;
        self.st.pending = Some(Pending {
            kind: PendingKind::Remove {
                next_control,
                next_owner,
            },
            commit: commit.to_bytes().map_err(mls)?,
            at: self.st.log_count,
            hash_at: self.st.log_hash.clone(),
            phase: 0,
            followups: vec![],
            proposals,
        });
        Ok(())
    }

    /// Admin: whether the control log has too little room left for the
    /// proposals to copy, the next commit, what follows it and a `Move`
    /// (§B3.1, §B5.1).
    pub fn needs_rotation(&self) -> bool {
        self.is_admin()
            && self.st.move_state == MoveState::Stable
            && self.st.log_count + LOG_RESERVE + Self::chunks_of(&self.copies_for_commit())
                > LOG_SUBKEYS
    }

    /// Admin: stage moving the group to a new generation without removing
    /// anyone, because the control log is (nearly) full (§B3.1, F20). Then
    /// `publish_pending`, exactly like a removal minus the `Remove` commit.
    pub fn stage_rotate(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        if self.st.pending.is_some() {
            return Err(PocError::Rejected(
                "a commit is pending: publish it first".into(),
            ));
        }
        if !self.is_admin() {
            return Err(PocError::Rejected("only the admin rotates".into()));
        }
        let (next_control, next_owner) = dht.create()?;
        let header = ControlHeader {
            v: 2,
            gen: self.st.gen + 1,
            epoch: self.st.epoch,
            log_count: 0,
            prev: String::new(),
        };
        dht.set(&next_control, 0, &header.encode(), &next_owner)?;
        // Proposals waiting (e.g. Updates) go into this one commit: MLS
        // sends nothing while proposals are pending. What is left of the
        // log has to hold their copies, the commit (two subkeys at most)
        // and the Move; proposals that do not fit are dropped (their
        // senders propose again), and with none left, no commit at all.
        let room = LOG_SUBKEYS.saturating_sub(self.st.log_count + 3);
        while !self.st.proposal_copies.is_empty()
            && Self::chunks_of(&self.copies_for_commit()) > room
        {
            let (r, _) = self.st.proposal_copies.pop().expect("not empty");
            self.drop_proposal(&r)?;
        }
        let proposals = self.copies_for_commit();
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        let commit = if proposals.is_empty() {
            if group.pending_proposals().next().is_some() {
                // Only the admin's own proposals: not needed (its commits
                // refresh its leaf anyway); members get a commit soon.
                group
                    .clear_pending_proposals(self.provider.storage())
                    .map_err(mls)?;
                self.st.commit_due = true;
            }
            vec![]
        } else {
            let (commit, _, _) = group
                .commit_to_pending_proposals(&self.provider, &self.signer)
                .map_err(mls)?;
            commit.to_bytes().map_err(mls)?
        };
        self.st.pending = Some(Pending {
            kind: PendingKind::Rotate {
                next_control,
                next_owner,
            },
            commit,
            at: self.st.log_count,
            hash_at: self.st.log_hash.clone(),
            phase: 0,
            followups: vec![],
            proposals,
        });
        Ok(())
    }

    /// Admin: drops one stored proposal (it did not fit, §B5.1).
    fn drop_proposal(&mut self, r: &[u8]) -> Result<(), PocError> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        let found = group
            .pending_proposals()
            .find(|q| q.proposal_reference_ref().as_slice() == r)
            .map(|q| q.proposal_reference_ref().clone());
        if let Some(found) = found {
            group
                .remove_pending_proposal(self.provider.storage(), &found)
                .map_err(mls)?;
            self.st.commit_due = true;
            self.st
                .events
                .push("a proposal did not fit the log: dropped".into());
        }
        Ok(())
    }

    /// Admin: commits the queued proposals (e.g. members' Updates, F13),
    /// copied into the log before the commit (§B5.1). With none, an empty
    /// commit that refreshes the admin's own leaf.
    pub fn stage_commit_proposals(&mut self) -> Result<(), PocError> {
        self.require_no_pending()?;
        let proposals = self.copies_for_commit();
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        let (commit, _, _) = group
            .commit_to_pending_proposals(&self.provider, &self.signer)
            .map_err(mls)?;
        self.st.pending = Some(Pending {
            kind: PendingKind::Proposals,
            commit: commit.to_bytes().map_err(mls)?,
            at: self.st.log_count,
            hash_at: self.st.log_hash.clone(),
            phase: 0,
            followups: vec![],
            proposals,
        });
        Ok(())
    }

    /// Admin: stages handing the admin role to `to` (§B5.4): an
    /// `AdminTransfer` in the log, published like a commit (resumable).
    /// Waiting proposals are committed first.
    pub fn stage_handover(&mut self, to: &str) -> Result<(), PocError> {
        self.require_no_pending()?;
        if to == self.st.cik || !self.members().iter().any(|m| m == to) {
            return Err(PocError::Rejected(
                "hand over only to another current member".into(),
            ));
        }
        if self.pending_proposals() > 0 {
            return Err(PocError::Rejected(
                "proposals are waiting: commit them first".into(),
            ));
        }
        if self.st.move_state != MoveState::Stable {
            return Err(PocError::Rejected(
                "the group is moving: hand over afterwards".into(),
            ));
        }
        self.st.pending = Some(Pending {
            kind: PendingKind::Handover { to: to.into() },
            commit: vec![],
            at: self.st.log_count,
            hash_at: self.st.log_hash.clone(),
            phase: 0,
            followups: vec![],
            proposals: vec![],
        });
        Ok(())
    }

    /// Admin: publishes the pending commit (all phases).
    pub fn publish_pending(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        while self.st.pending.is_some() {
            self.publish_step(dht)?;
        }
        // After a removal the admin moves to its new outbox right away.
        self.step_move(dht)?;
        self.step_move(dht)?;
        Ok(())
    }

    /// Admin: one publishing phase. A restart between phases resumes with
    /// identical writes, never a second, different commit (F9).
    pub fn publish_step(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        let Some(mut p) = self.st.pending.clone() else {
            return Ok(());
        };
        match p.phase {
            0 => {
                self.st.log_count = p.at;
                self.st.log_hash = p.hash_at.clone();
                self.append_commit(dht, &p)?;
                p.phase = 1;
            }
            1 => {
                let group = self.group.as_mut().expect("admin has a group");
                if group.pending_commit().is_some() {
                    group.merge_pending_commit(&self.provider).map_err(mls)?;
                }
                let epoch = group.epoch().as_u64();
                if epoch != self.st.epoch {
                    self.epoch_changed();
                }
                self.st.epoch = epoch;
                p.followups = match &p.kind {
                    PendingKind::Add { joiners, .. } => {
                        for j in joiners {
                            self.st.outboxes.insert(j.cik.clone(), j.outbox.clone());
                        }
                        vec![self.directory_message()?]
                    }
                    // B5.3 step 3: the Move, encrypted in the new epoch, so
                    // the removed member cannot read where the group went.
                    PendingKind::Remove { next_control, .. } => {
                        vec![self.encrypt(&AppMsg::Move {
                            gen: self.st.gen + 1,
                            control: next_control.clone(),
                        })?]
                    }
                    // The directory again: this is how a changed successor
                    // list reaches the members (an empty commit is enough),
                    // through the same resumable publication (F9).
                    PendingKind::Proposals => vec![self.directory_message()?],
                    // §B3.1: the same Move, in the current epoch (nobody is
                    // removed, so everyone may read where the group went).
                    PendingKind::Rotate { next_control, .. } => {
                        vec![self.encrypt(&AppMsg::Move {
                            gen: self.st.gen + 1,
                            control: next_control.clone(),
                        })?]
                    }
                    PendingKind::Handover { to } => {
                        vec![self.encrypt(&AppMsg::AdminTransfer { to: to.clone() })?]
                    }
                };
                p.phase = 2;
            }
            _ => {
                // Positions right after the commit, same bytes every time.
                self.st.log_count = p.at;
                self.st.log_hash = p.hash_at.clone();
                self.append_commit(dht, &p)?;
                for f in &p.followups {
                    self.append_log(dht, Kind::Mls, f)?;
                }
                self.write_header(dht)?;
                match &p.kind {
                    PendingKind::Add { welcome, joiners } => {
                        let control = self.st.control.clone().expect("admin has control");
                        let answer = JoinAnswer {
                            welcome: welcome.clone(),
                            control,
                            gen: self.st.gen,
                        }
                        .encode();
                        for j in joiners {
                            for (i, c) in wire::chunk(Kind::Welcome, &answer).iter().enumerate() {
                                dht.set(
                                    &j.rendezvous,
                                    ANSWER_FIRST + i as u32,
                                    c,
                                    &j.rendezvous_owner,
                                )?;
                            }
                            // One-time invite.
                            self.st.invites.remove(&j.rendezvous);
                            self.st.invite_for.remove(&j.rendezvous);
                        }
                    }
                    PendingKind::Remove {
                        next_control,
                        next_owner,
                    } => {
                        // B5.3 step 4: mirror the commit into the new log;
                        // the admin then moves like every member.
                        let gen = self.st.gen + 1;
                        self.st.control_owner = Some(next_owner.clone());
                        self.st.control = Some(next_control.clone());
                        self.st.gen = gen;
                        self.st.log_count = 0;
                        self.st.log_hash = String::new();
                        self.append_commit(dht, &p)?;
                        self.write_header(dht)?;
                        self.st.move_state = MoveState::Moving {
                            gen,
                            control: next_control.clone(),
                        };
                    }
                    PendingKind::Proposals => {}
                    PendingKind::Rotate {
                        next_control,
                        next_owner,
                    } => {
                        // The new log starts empty (its header was written
                        // when staging); the admin moves like every member.
                        let gen = self.st.gen + 1;
                        self.st.control_owner = Some(next_owner.clone());
                        self.st.control = Some(next_control.clone());
                        self.st.gen = gen;
                        self.st.log_count = 0;
                        self.st.log_hash = String::new();
                        self.st.move_state = MoveState::Moving {
                            gen,
                            control: next_control.clone(),
                        };
                    }
                    PendingKind::Handover { to } => {
                        // From here on `to` is the admin; it starts g + 1.
                        self.st.admin_cik = to.clone();
                        self.st.successors.retain(|s| s != to);
                        self.st.proposal_copies.clear();
                        self.st.invites.clear();
                        self.st.invite_for.clear();
                        self.st.events.push("admin role handed over".into());
                    }
                }
                self.st.pending = None;
                return Ok(());
            }
        }
        self.st.pending = Some(p);
        Ok(())
    }

    /// Admin: who has which outbox, and the successor list (in the log, so
    /// members get it in order and E2EE).
    fn directory_message(&mut self) -> Result<Vec<u8>, PocError> {
        self.encrypt(&AppMsg::Directory {
            gen: self.st.gen,
            outboxes: self.st.outboxes.clone().into_iter().collect(),
            successors: self.st.successors.clone(),
        })
    }

    /// Admin: re-publishes the directory (after changing successors).
    pub fn publish_directory_now(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        let msg = self.directory_message()?;
        self.append_log(dht, Kind::Mls, &msg)?;
        self.write_header(dht)
    }

    /// Test hook: the admin appends raw bytes to its log (duplicates and
    /// replays, F3/F4).
    pub fn append_raw_for_test(&mut self, dht: &mut dyn Dht, msg: &[u8]) -> Result<(), PocError> {
        self.append_log(dht, Kind::Mls, msg)?;
        self.write_header(dht)
    }

    /// The copied proposals, then the commit (§B5.1).
    fn append_commit(&mut self, dht: &mut dyn Dht, p: &Pending) -> Result<(), PocError> {
        if p.commit.is_empty() {
            return Ok(());
        }
        for m in &p.proposals {
            self.append_log(dht, Kind::Mls, m)?;
        }
        self.append_log(dht, Kind::Mls, &p.commit)
    }

    fn append_log(&mut self, dht: &mut dyn Dht, kind: Kind, msg: &[u8]) -> Result<(), PocError> {
        let control = self.st.control.clone().expect("admin has control");
        let owner = self.st.control_owner.clone().expect("admin owns control");
        let chunks = wire::chunk(kind, msg);
        // §B3.1: never past the log's subkeys (the reserve normally keeps
        // a rotation's Move well inside).
        if self.st.log_count + chunks.len() as u32 > LOG_SUBKEYS {
            return Err(PocError::Rejected("control log full".into()));
        }
        self.track_log(&control);
        for c in chunks {
            self.st.log_count += 1;
            dht.set(&control, self.st.log_count, &c, &owner)?;
            self.st.log_written.insert(self.st.log_count, c.clone());
            self.st.log_hash = chain(&self.st.log_hash, &c);
            self.note_log_hash();
        }
        Ok(())
    }

    /// Starts tracking unconfirmed writes anew for a different log.
    fn track_log(&mut self, control: &RecordId) {
        if self.st.log_written_for.as_ref() != Some(control) {
            self.st.log_written.clear();
            self.st.log_written_for = Some(control.clone());
        }
    }

    /// Admin (F16): reads back what it wrote to its control log and not yet
    /// saw on the network; a value or header a storage node dropped is
    /// written again with the same bytes (idempotent, like a resumed
    /// publication). Members only wait for such values (they cannot write
    /// the log), so this is what lets them continue.
    fn repair_own_log(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        if !self.is_admin() || self.st.pending.is_some() {
            return Ok(());
        }
        let (Some(control), Some(owner)) = (self.st.control.clone(), self.st.control_owner.clone())
        else {
            return Ok(());
        };
        if self.st.log_written_for.as_ref() != Some(&control) {
            return Ok(());
        }
        let mut repaired = false;
        for (k, v) in self.st.log_written.clone() {
            match dht.get(&control, k)? {
                Some(cur) if cur == v => {
                    self.st.log_written.remove(&k);
                }
                _ => {
                    dht.set(&control, k, &v, &owner)?;
                    repaired = true;
                }
            }
        }
        if self.st.header_unverified {
            let ok = dht
                .get(&control, 0)?
                .and_then(|raw| ControlHeader::decode(&raw).ok())
                .is_some_and(|h| {
                    h.gen == self.st.gen
                        && h.log_count == self.st.log_count
                        && h.prev == self.st.log_hash
                });
            if ok {
                self.st.header_unverified = false;
            } else {
                self.write_header(dht)?;
                repaired = true;
            }
        }
        if repaired {
            self.st
                .events
                .push("re-wrote lost control log values".into());
        }
        Ok(())
    }

    /// Remembers `logHash` at the current position of this generation.
    fn note_log_hash(&mut self) {
        let gen = self.st.gen;
        self.st
            .log_hashes
            .retain(|k, _| k.split(':').next() == Some(gen.to_string().as_str()));
        self.st.log_hashes.insert(
            format!("{gen}:{}", self.st.log_count),
            self.st.log_hash.clone(),
        );
    }

    /// The `ctl` this member reports in its messages (B8).
    fn ctl(&self) -> wire::Ctl {
        wire::Ctl {
            gen: self.st.gen,
            log_count: self.st.log_count,
            log_hash: self.st.log_hash.clone(),
        }
    }

    /// B5.2 r6: a peer that accepted a different log for a position this
    /// member has also accepted means the histories diverged.
    fn check_ctl(&mut self, from: &str, ctl: &wire::Ctl) {
        if ctl.gen != self.st.gen || ctl.log_count == 0 || self.st.history_diverged {
            return;
        }
        let mine = self
            .st
            .log_hashes
            .get(&format!("{}:{}", ctl.gen, ctl.log_count));
        if let Some(mine) = mine {
            if *mine != ctl.log_hash {
                self.st.history_diverged = true;
                self.st.events.push(format!(
                    "group history differs from {from} at log position {}",
                    ctl.log_count
                ));
            }
        }
    }

    /// Test hook (F19): the admin rewrites an already published log
    /// position with a fresh encryption of the current Directory, and
    /// re-signs the header over the new chain, as an equivocating admin
    /// would.
    pub fn rewrite_log_for_test(&mut self, dht: &mut dyn Dht, pos: u32) -> Result<(), PocError> {
        let control = self.st.control.clone().expect("admin has control");
        let owner = self.st.control_owner.clone().expect("admin owns control");
        let msg = self.directory_message()?;
        let chunks = wire::chunk(Kind::Mls, &msg);
        assert_eq!(chunks.len(), 1, "test rewrites a one-chunk entry");
        dht.set(&control, pos, &chunks[0], &owner)?;
        // The equivocating admin keeps its new version (no F16 repair back).
        self.st.log_written.insert(pos, chunks[0].clone());
        let mut h = String::new();
        for k in 1..=self.st.log_count {
            let v = dht.get(&control, k)?.expect("own log value");
            h = chain(&h, &v);
            self.st
                .log_hashes
                .insert(format!("{}:{k}", self.st.gen), h.clone());
        }
        self.st.log_hash = h;
        self.write_header(dht)
    }

    fn write_header(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        let control = self.st.control.clone().expect("admin has control");
        let owner = self.st.control_owner.clone().expect("admin owns control");
        self.track_log(&control);
        self.st.header_unverified = true;
        let header = ControlHeader {
            v: 2,
            gen: self.st.gen,
            epoch: self.st.epoch,
            log_count: self.st.log_count,
            prev: self.st.log_hash.clone(),
        };
        dht.set(&control, 0, &header.encode(), &owner)?;
        Ok(())
    }

    /// Joiner: picks up the Welcome once the admin answered.
    pub fn complete_join(&mut self, dht: &mut dyn Dht, invite: &Invite) -> Result<bool, PocError> {
        let Some(first) = dht.get(&invite.rendezvous, ANSWER_FIRST)? else {
            return Ok(false);
        };
        let total = wire::parse_chunk(&first)
            .map_err(|e| PocError::Rejected(e.to_string()))?
            .total as u32;
        if total == 0 || total > ANSWER_SUBKEYS {
            return Err(PocError::Rejected("malformed answer".into()));
        }
        let mut values = vec![first];
        for k in ANSWER_FIRST + 1..ANSWER_FIRST + total {
            match dht.get(&invite.rendezvous, k)? {
                Some(v) => values.push(v),
                None => return Ok(false), // still propagating (F1)
            }
        }
        let (kind, body) =
            wire::reassemble(&values).map_err(|e| PocError::Rejected(e.to_string()))?;
        if kind != Kind::Welcome {
            return Err(PocError::Rejected("not a welcome".into()));
        }
        let answer = JoinAnswer::decode(&body)
            .ok_or_else(|| PocError::Rejected("malformed welcome".into()))?;
        let welcome = match MlsMessageIn::tls_deserialize_exact(answer.welcome.as_slice())
            .map_err(mls)?
            .extract()
        {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err(PocError::Rejected("not a welcome".into())),
        };
        let group = StagedWelcome::new_from_welcome(&self.provider, &join_config(), welcome, None)
            .map_err(mls)?
            .into_group(&self.provider)
            .map_err(mls)?;
        // Only 0x0003: the provider also carries P-256/P-384 code (with a
        // known timing advisory in crypto-bigint 0.5), which an admin must
        // not be able to steer a joiner into.
        if group.ciphersuite() != CIPHERSUITE {
            return Err(PocError::Rejected("group uses another ciphersuite".into()));
        }
        self.st.group_id = Some(group.group_id().as_slice().to_vec());
        self.st.epoch = group.epoch().as_u64();
        self.group = Some(group);
        self.st.admin_cik = invite.admin_cik.clone();
        self.st.control = Some(answer.control);
        self.st.gen = answer.gen;
        // Start reading the log where the Welcome put us: entries for
        // earlier epochs are skipped as old (B5.2 r2).
        self.st.log_count = 0;
        self.st.log_hash = String::new();
        self.st.last_admin_activity = dht.now();
        let me = self.st.cik.clone();
        let outbox = self
            .st
            .my_outbox
            .clone()
            .expect("created in request_join")
            .0;
        self.st.outboxes.insert(me, outbox);
        Ok(true)
    }

    // ----------------------------------------------------------- sending

    fn encrypt(&mut self, msg: &AppMsg) -> Result<Vec<u8>, PocError> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        group
            .create_message(&self.provider, &self.signer, &msg.encode())
            .map_err(mls)?
            .to_bytes()
            .map_err(mls)
    }

    fn write_outbox(&mut self, dht: &mut dyn Dht, kind: Kind, msg: &[u8]) -> Result<(), PocError> {
        let (outbox, secret) = self
            .st
            .my_outbox
            .clone()
            .ok_or_else(|| PocError::Rejected("no outbox".into()))?;
        for c in wire::chunk(kind, msg) {
            self.st.my_count += 1;
            let p = self.st.my_count;
            let v = with_position(p, &c);
            dht.set(&outbox, ring_slot(p), &v, &secret)?;
            self.st.sent.insert(p, v);
        }
        // Only what the ring still holds can be re-sent (F16).
        let floor = self.st.my_count.saturating_sub(OUTBOX_RING);
        self.st.sent.retain(|p, _| *p > floor);
        dht.set(
            &outbox,
            0,
            &OutboxHead {
                count: self.st.my_count,
            }
            .encode(),
            &secret,
        )?;
        Ok(())
    }

    /// Sends a text message; returns the MLS ciphertext size.
    pub fn send_text(&mut self, dht: &mut dyn Dht, text: &str) -> Result<usize, PocError> {
        let msg = AppMsg::Text {
            id: wire::hex(&self.random(16)),
            seq: self.st.my_seq + 1,
            text: text.into(),
            prev: self.st.my_prev.clone(),
            ctl: self.ctl(),
        };
        // §B3.1, F22: the outbox ring only fits messages up to the
        // 4096-byte padding bucket. Refused before anything changes.
        if msg.encode().len() > MAX_PLAINTEXT {
            return Err(PocError::Rejected("message too long".into()));
        }
        self.st.my_seq += 1;
        self.st.my_prev = wire::sha256_hex(&msg.encode());
        let bytes = self.encrypt(&msg)?;
        self.write_outbox(dht, Kind::Mls, &bytes)?;
        Ok(bytes.len())
    }

    /// Sends an Update proposal (fresh leaf key) for the admin to commit.
    pub fn propose_update(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        let (msg, _) = group
            .propose_self_update(&self.provider, &self.signer, LeafNodeParameters::default())
            .map_err(mls)?;
        let bytes = msg.to_bytes().map_err(mls)?;
        // Its copy in the log is skipped (§B5.1): we cannot decrypt it.
        self.st.my_proposals.insert(wire::sha256_hex(&bytes));
        self.write_outbox(dht, Kind::Mls, &bytes)
    }

    /// Re-sends own outbox values the network lost (F16).
    fn repair_own_outbox(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        let Some((outbox, secret)) = self.st.my_outbox.clone() else {
            return Ok(());
        };
        let mut repaired = false;
        for (p, v) in self.st.sent.clone() {
            if matches!(read_slot(dht, &outbox, p)?, Slot::NotYet) {
                dht.set(&outbox, ring_slot(p), &v, &secret)?;
                repaired = true;
            }
        }
        if repaired {
            self.st.events.push("re-sent lost outbox values".into());
        }
        Ok(())
    }

    // ---------------------------------------------------------- receiving

    /// One round: own outbox repair, others' outboxes (proposals, texts),
    /// then the control log (commits), then the move state machine.
    pub fn sync(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        self.sync_with_move_steps(dht, 4)
    }

    /// Like [`Member::sync`], with at most `move_steps` steps of a pending
    /// generation move (tests restart the member between steps, F8).
    pub fn sync_with_move_steps(
        &mut self,
        dht: &mut dyn Dht,
        move_steps: usize,
    ) -> Result<(), PocError> {
        if self.group.is_none() {
            return Ok(());
        }
        self.repair_own_outbox(dht)?;
        self.repair_own_log(dht)?;
        if self.removed_stop() {
            return Ok(());
        }
        self.sync_outboxes(dht)?;
        self.sync_control(dht)?;
        self.sync_outboxes(dht)?;
        self.start_after_handover(dht)?;
        for _ in 0..move_steps {
            self.step_move(dht)?;
        }
        Ok(())
    }

    /// Senders whose chain still has a missing message.
    pub fn real_gaps(&self) -> usize {
        self.st.awaiting.values().map(|s| s.len()).sum()
    }

    fn removed_stop(&self) -> bool {
        self.st.removed
    }

    fn sync_control(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        let Some(control) = self.st.control.clone() else {
            return Ok(());
        };
        // B5.2 r6: after diverging histories no further commit is accepted.
        if self.st.history_diverged {
            return Ok(());
        }
        let Some(raw) = dht.get(&control, 0)? else {
            return Ok(());
        };
        let header = match ControlHeader::decode(&raw) {
            Ok(h) => h,
            Err(_) => {
                self.st
                    .events
                    .push("malformed control header ignored".into());
                return Ok(());
            }
        };
        // B5.2 r3: a storage node serving an older value.
        if header.gen != self.st.gen
            || header.log_count < self.st.log_count
            || header.epoch < self.st.epoch && header.log_count <= self.st.log_count
        {
            if header.gen < self.st.gen || header.log_count < self.st.log_count {
                self.st
                    .events
                    .push("rollback of control record ignored".into());
            }
            return Ok(());
        }
        if header.log_count == self.st.log_count {
            if header.prev != self.st.log_hash {
                self.st
                    .events
                    .push("control header does not chain: rejected".into());
            }
            return Ok(());
        }
        // Read the new entries; all of them must be there (F1) and chain
        // to the header (B5.2 r4).
        let mut values = vec![];
        let mut h = self.st.log_hash.clone();
        for k in self.st.log_count + 1..=header.log_count {
            match dht.get(&control, k)? {
                Some(v) => {
                    h = chain(&h, &v);
                    values.push(v);
                }
                None => return Ok(()), // not propagated yet: wait
            }
        }
        if h != header.prev {
            self.st
                .events
                .push("control log does not match its header: rejected".into());
            return Ok(());
        }
        let messages = match split_messages(&values) {
            Ok(m) => m,
            Err(_) => {
                self.st.events.push("malformed control log rejected".into());
                return Ok(());
            }
        };
        let base = self.st.log_count;
        let mut consumed = 0u32;
        for (len, kind, body) in messages {
            if kind != Kind::Mls {
                self.st
                    .events
                    .push("unexpected entry in control log ignored".into());
            } else if !self.handle_control_entry(dht, &body)? {
                // A commit we cannot apply yet (e.g. a proposal it refers
                // to has not arrived): stop here and retry next round.
                break;
            }
            consumed += len;
            // Accepted up to here.
            self.st.log_count = base + consumed;
            self.st.log_hash = chain_all(
                &self.st.log_hash,
                &values[(consumed - len) as usize..consumed as usize],
            );
            self.note_log_hash();
            if self.st.removed
                || self.st.move_state != MoveState::Stable && self.st.gen != header.gen
            {
                break;
            }
        }
        Ok(())
    }

    /// Returns false when the entry has to be retried later.
    fn handle_control_entry(&mut self, dht: &mut dyn Dht, body: &[u8]) -> Result<bool, PocError> {
        let Ok(msg) = MlsMessageIn::tls_deserialize_exact(body) else {
            self.st.events.push("malformed log entry ignored".into());
            return Ok(true);
        };
        let Ok(proto) = msg.try_into_protocol_message() else {
            self.st.events.push("non-protocol log entry ignored".into());
            return Ok(true);
        };
        let group = self.group.as_mut().expect("synced only with a group");
        let current = group.epoch().as_u64();
        let msg_epoch = proto.epoch().as_u64();
        let handshake = proto.content_type() != ContentType::Application;
        let proposal = proto.content_type() == ContentType::Proposal;
        if proposal && self.st.my_proposals.contains(&wire::sha256_hex(body)) {
            // Our own Update, copied by the admin: already in our store.
            return Ok(true);
        }
        // B5.2 r1/r2: commits only for exactly the current epoch (which they
        // advance); older ones are duplicates or replays.
        if handshake && msg_epoch < current {
            self.st
                .events
                .push(format!("old commit for epoch {msg_epoch} ignored"));
            return Ok(true);
        }
        if handshake && msg_epoch > current {
            self.st
                .events
                .push(format!("commit for future epoch {msg_epoch}: waiting"));
            return Ok(false);
        }
        let processed = match group.process_message(&self.provider, proto) {
            Ok(p) => p,
            Err(e) => {
                let e = format!("{e:?}");
                if proposal {
                    // A copy we cannot use; if its commit needs it, the
                    // commit waits and says so.
                    self.st
                        .events
                        .push(format!("proposal copy in the log not usable: {e}"));
                    return Ok(true);
                }
                if handshake {
                    // Typically a proposal it references is not here yet.
                    self.st
                        .events
                        .push(format!("commit not applicable yet: {e}"));
                    return Ok(false);
                }
                self.st.undecryptable += 1;
                self.st
                    .events
                    .push(format!("log message not decryptable: {e}"));
                return Ok(true);
            }
        };
        let sender_cik = sender_key(group, &processed);
        let from_admin = sender_cik == self.st.admin_cik;
        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                if !from_admin {
                    self.st
                        .events
                        .push("commit not signed by the admin: rejected".into());
                    // Drop OpenMLS's staged state; nothing was merged.
                    return Ok(true);
                }
                let removed_me = staged.self_removed();
                group
                    .merge_staged_commit(&self.provider, *staged)
                    .map_err(mls)?;
                self.st.epoch = group.epoch().as_u64();
                self.epoch_changed();
                self.st.last_admin_activity = dht.now();
                if removed_me {
                    self.st.removed = true;
                    self.st.events.push("removed from the group".into());
                }
            }
            ProcessedMessageContent::ApplicationMessage(app) => {
                if !from_admin {
                    self.st
                        .events
                        .push("log message not from the admin ignored".into());
                    return Ok(true);
                }
                self.st.last_admin_activity = dht.now();
                match AppMsg::decode(&app.into_bytes()) {
                    Ok(AppMsg::Directory {
                        gen,
                        outboxes,
                        successors,
                    }) if gen == self.st.gen => {
                        for (cik, outbox) in outboxes {
                            if cik != self.st.cik {
                                self.st.outboxes.insert(cik, outbox);
                            }
                        }
                        self.st.successors = successors;
                    }
                    Ok(AppMsg::Move { gen, control }) if gen == self.st.gen + 1 => {
                        // Also during an unfinished move: a second removal
                        // starts g+2 from g+1 and members follow the chain
                        // of Move pointers (B5.3). Members still awaited for
                        // the previous move no longer matter.
                        let newer = match &self.st.move_state {
                            MoveState::Stable => true,
                            MoveState::Moving { gen: g, .. }
                            | MoveState::Created { gen: g, .. }
                            | MoveState::Announced { gen: g, .. } => gen > *g,
                        };
                        if newer {
                            if self.st.move_state != MoveState::Stable {
                                self.st
                                    .events
                                    .push(format!("move to gen {gen} during an unfinished move"));
                            }
                            self.st.move_state = MoveState::Moving { gen, control };
                        }
                    }
                    // §B5.4: from this log position on, `to` is the admin;
                    // later entries signed by the old admin are rejected.
                    Ok(AppMsg::AdminTransfer { to }) => {
                        let current = self.members().contains(&to);
                        if current && to != self.st.admin_cik {
                            self.st.admin_cik = to.clone();
                            self.st.successors.retain(|s| *s != to);
                            self.st.events.push("admin role handed over".into());
                            if to == self.st.cik {
                                self.st.handover_due = true;
                            }
                            let early = self.st.early_takeovers.remove(&to);
                            if let Some((gen, control)) = early {
                                if gen == self.st.gen + 1 && self.st.move_state == MoveState::Stable
                                {
                                    self.st.move_state = MoveState::Moving { gen, control };
                                }
                            }
                        } else {
                            self.st
                                .events
                                .push("handover to a non-member ignored".into());
                        }
                    }
                    Ok(other) => self
                        .st
                        .events
                        .push(format!("unexpected log message {other:?}")),
                    Err(_) => self.st.events.push("malformed log message ignored".into()),
                }
            }
            ProcessedMessageContent::ProposalMessage(p) => {
                group
                    .store_pending_proposal(self.provider.storage(), *p)
                    .map_err(mls)?;
            }
            _ => {}
        }
        Ok(true)
    }

    /// Reads every followed outbox (and old ones during a move).
    fn sync_outboxes(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        let mut targets: Vec<(String, RecordId)> = self
            .st
            .outboxes
            .iter()
            .filter(|(c, _)| **c != self.st.cik)
            .map(|(c, o)| (c.clone(), o.clone()))
            .collect();
        targets.extend(
            self.st
                .old_outboxes
                .iter()
                .map(|(c, o)| (c.clone(), o.clone())),
        );
        for (cik, outbox) in targets {
            self.read_outbox(dht, &cik, &outbox)?;
        }
        Ok(())
    }

    fn read_outbox(
        &mut self,
        dht: &mut dyn Dht,
        owner: &str,
        outbox: &RecordId,
    ) -> Result<(), PocError> {
        let count = match dht.get(outbox, 0)? {
            Some(v) => match OutboxHead::decode(&v) {
                Ok(h) => h.count,
                Err(_) => {
                    self.st.events.push("malformed outbox head ignored".into());
                    return Ok(());
                }
            },
            None => return Ok(()),
        };
        let mut cur = self.st.cursors.get(outbox).cloned().unwrap_or(Cursor {
            next: 1,
            missing: BTreeSet::new(),
        });
        // Positions at or below `floor` are already overwritten by the ring
        // (§B3.1): whatever we had not read there is a gap (F21).
        let floor = count.saturating_sub(OUTBOX_RING);
        let mut lost = cur.missing.iter().filter(|p| **p <= floor).count() as u32;
        if cur.next <= floor {
            lost += floor + 1 - cur.next.max(1);
        }
        // Retry earlier gaps first, then new positions.
        let mut starts: Vec<u32> = cur.missing.iter().copied().filter(|p| *p > floor).collect();
        let mut p = cur.next.max(floor + 1).max(1);
        let mut new_missing = BTreeSet::new();
        while p <= count {
            starts.push(p);
            p += 1;
        }
        cur.missing.clear();
        let mut done = BTreeSet::new();
        for s in starts {
            if done.contains(&s) {
                continue;
            }
            let first = match read_slot(dht, outbox, s)? {
                Slot::Value(v) => v,
                Slot::NotYet => {
                    new_missing.insert(s);
                    continue;
                }
                Slot::Overwritten => {
                    lost += 1;
                    continue;
                }
                Slot::Malformed => {
                    self.st.events.push("malformed outbox value ignored".into());
                    continue;
                }
            };
            let Ok(chunk) = wire::parse_chunk(&first) else {
                self.st.events.push("malformed outbox value ignored".into());
                continue;
            };
            if chunk.index != 0 {
                continue; // middle of a message read from its start
            }
            let mut values = vec![first.clone()];
            let mut complete = true;
            for k in s + 1..s + chunk.total as u32 {
                done.insert(k);
                match read_slot(dht, outbox, k)? {
                    Slot::Value(v) => values.push(v),
                    Slot::Overwritten => {
                        lost += 1;
                        complete = false;
                    }
                    _ => complete = false,
                }
            }
            if !complete {
                new_missing.insert(s);
                continue;
            }
            match wire::reassemble(&values) {
                Ok((Kind::Mls, body)) => {
                    if !self.handle_outbox_message(dht, owner, &body)? {
                        new_missing.insert(s); // from a future epoch: retry
                    }
                }
                _ => self
                    .st
                    .events
                    .push("malformed outbox message ignored".into()),
            }
        }
        cur.next = count + 1;
        cur.missing = new_missing;
        self.st.cursors.insert(outbox.clone(), cur);
        if lost > 0 {
            self.st.lost_messages += lost;
            self.st.events.push(format!(
                "{lost} older message(s) from {owner} no longer available (outbox ring)"
            ));
        }
        Ok(())
    }

    /// Returns false when the message has to be retried later (it belongs
    /// to an epoch whose commit we have not seen yet, F1).
    fn handle_outbox_message(
        &mut self,
        dht: &mut dyn Dht,
        owner: &str,
        body: &[u8],
    ) -> Result<bool, PocError> {
        let Ok(msg) = MlsMessageIn::tls_deserialize_exact(body) else {
            self.st.events.push("malformed outbox entry ignored".into());
            return Ok(true);
        };
        let Ok(proto) = msg.try_into_protocol_message() else {
            return Ok(true);
        };
        let content_type = proto.content_type();
        if content_type == ContentType::Proposal
            && (!self.is_admin() || self.st.proposal_copies.len() >= MAX_COPIED)
        {
            // §B5.1: only the admin takes proposals from outboxes; members
            // get them from the log, and must not decrypt them here (that
            // would use up the key the log copy needs).
            if self.is_admin() {
                self.st.commit_due = true; // over MAX_COPIED: commit soon
            }
            return Ok(true);
        }
        let group = self.group.as_mut().expect("synced only with a group");
        let msg_epoch = proto.epoch().as_u64();
        let current = group.epoch().as_u64();
        if msg_epoch > current {
            return Ok(false);
        }
        if content_type == ContentType::Commit && msg_epoch < current {
            // Someone else committed an epoch we already left through the
            // admin's commit: if it is the successor, the group forked (F14).
            let successor = self.st.successors.first().map(String::as_str) == Some(owner);
            if successor && owner != self.st.admin_cik {
                self.st.fork_suspected = true;
                self.st
                    .events
                    .push("fork: the successor committed an epoch we left via the admin".into());
            } else {
                self.st.events.push(format!(
                    "old commit for epoch {msg_epoch} in an outbox ignored"
                ));
            }
            return Ok(true);
        }
        let processed = match group.process_message(&self.provider, proto) {
            Ok(p) => p,
            Err(e) => {
                self.st.undecryptable += 1;
                self.st.events.push(format!(
                    "outbox message not decryptable (epoch {msg_epoch}): {e:?}"
                ));
                return Ok(true);
            }
        };
        let sender_cik = sender_key(group, &processed);
        if sender_cik != owner {
            self.st
                .events
                .push("message in someone else's outbox ignored".into());
            return Ok(true);
        }
        if sender_cik == self.st.admin_cik {
            self.st.last_admin_activity = dht.now();
        }
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app) => {
                let bytes = app.into_bytes();
                match AppMsg::decode(&bytes) {
                    Ok(AppMsg::Text {
                        text, prev, ctl, ..
                    }) => {
                        self.check_ctl(&sender_cik, &ctl);
                        // `prev` chain: a referenced message not seen yet is
                        // awaited; it stops being a gap when it arrives.
                        let h = wire::sha256_hex(&bytes);
                        self.st.seen.insert(h.clone());
                        if let Some(waiting) = self.st.awaiting.get_mut(&sender_cik) {
                            waiting.remove(&h);
                        }
                        if !prev.is_empty() && !self.st.seen.contains(&prev) {
                            self.st
                                .awaiting
                                .entry(sender_cik.clone())
                                .or_default()
                                .insert(prev);
                        }
                        self.st.awaiting.retain(|_, s| !s.is_empty());
                        self.st.inbox.push(Received {
                            from: sender_cik,
                            text,
                            epoch: msg_epoch,
                        });
                    }
                    Ok(AppMsg::MyOutbox { gen, outbox }) => {
                        self.st.moved_to.insert(sender_cik, (gen, outbox));
                    }
                    Ok(AppMsg::Takeover { gen, control }) => {
                        if sender_cik == self.st.admin_cik
                            && self.st.move_state == MoveState::Stable
                        {
                            self.st.move_state = MoveState::Moving { gen, control };
                        } else if gen == self.st.gen + 1 {
                            // Outboxes are read before the log: the
                            // AdminTransfer naming this sender may follow
                            // (§B5.4). Kept until then, applied only if it
                            // does.
                            self.st.early_takeovers.insert(sender_cik, (gen, control));
                        }
                    }
                    Ok(other) => self
                        .st
                        .events
                        .push(format!("unexpected outbox message {other:?}")),
                    Err(_) => self.st.events.push("malformed message ignored".into()),
                }
            }
            ProcessedMessageContent::ProposalMessage(p) => {
                // Admin (checked above): stored, and kept as sent, to be
                // copied into the log before the commit (§B5.1).
                let r = p.proposal_reference_ref().as_slice().to_vec();
                group
                    .store_pending_proposal(self.provider.storage(), *p)
                    .map_err(mls)?;
                self.st.proposal_copies.push((r, body.to_vec()));
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                // Only a successor's takeover commit may come from an outbox
                // (B5.4), and only after the admin was silent long enough
                // and no admin commit exists for this epoch.
                let first_successor = self.st.successors.first().cloned().unwrap_or_default();
                let silent = dht.now().saturating_sub(self.st.last_admin_activity);
                if sender_cik == first_successor && silent >= T_SUCCESSOR {
                    group
                        .merge_staged_commit(&self.provider, *staged)
                        .map_err(mls)?;
                    self.st.epoch = group.epoch().as_u64();
                    self.epoch_changed();
                    self.st.admin_cik = sender_cik;
                    self.st.last_admin_activity = dht.now();
                    self.st
                        .events
                        .push("takeover by the first successor accepted".into());
                } else {
                    self.st.events.push("commit from an outbox rejected".into());
                }
            }
            _ => {}
        }
        Ok(true)
    }

    // -------------------------------------------- generation move (B5.3)

    /// One step of the move; every step is idempotent and persisted.
    pub fn step_move(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        match self.st.move_state.clone() {
            MoveState::Stable => {}
            MoveState::Moving { gen, control } => {
                let (outbox, secret) = self.new_outbox(dht)?;
                self.st.move_state = MoveState::Created {
                    gen,
                    control,
                    outbox,
                    secret,
                };
            }
            MoveState::Created {
                gen,
                control,
                outbox,
                secret,
            } => {
                // An own Update still waiting is never committed now: the
                // old log ends with the Move or the new admin's Takeover,
                // and every commit before it was already applied. MLS sends
                // nothing while it waits, so it goes; the next one is
                // proposed in the new generation.
                if self.my_update_pending() {
                    let group = self.group.as_mut().expect("member has a group");
                    group
                        .clear_pending_proposals(self.provider.storage())
                        .map_err(mls)?;
                    self.st.my_proposals.clear();
                    self.st
                        .events
                        .push("own update not committed before the move: dropped".into());
                }
                // Last message in the old outbox, in the new epoch.
                let note = self.encrypt(&AppMsg::MyOutbox {
                    gen,
                    outbox: outbox.clone(),
                })?;
                self.write_outbox(dht, Kind::Mls, &note)?;
                // From now on: new outbox, new control record.
                let me = self.st.cik.clone();
                let present: BTreeSet<String> = self.members().into_iter().collect();
                self.st.old_outboxes = self
                    .st
                    .outboxes
                    .iter()
                    .filter(|(c, _)| **c != me && present.contains(*c))
                    .map(|(c, o)| (c.clone(), o.clone()))
                    .collect();
                self.st.outboxes.clear();
                self.st.outboxes.insert(me, outbox.clone());
                self.st.my_outbox = Some((outbox.clone(), secret.clone()));
                self.st.my_count = 0;
                self.st.sent.clear();
                dht.set(&outbox, 0, &OutboxHead { count: 0 }.encode(), &secret)?;
                if !self.is_admin() {
                    self.st.control = Some(control.clone());
                    self.st.gen = gen;
                    self.st.log_count = 0;
                    self.st.log_hash = String::new();
                }
                self.st.move_state = MoveState::Announced {
                    gen,
                    control,
                    since: dht.now(),
                };
            }
            MoveState::Announced { gen, since, .. } => {
                // Switch members whose announcement arrived.
                for (cik, (g, outbox)) in self.st.moved_to.clone() {
                    if g == gen && self.st.old_outboxes.remove(&cik).is_some() {
                        self.st.outboxes.insert(cik, outbox);
                    }
                }
                let expired = dht.now().saturating_sub(since) >= GRACE;
                if self.st.old_outboxes.is_empty() || expired {
                    if expired && !self.st.old_outboxes.is_empty() {
                        self.st.events.push(format!(
                            "grace period over: {} member(s) did not move",
                            self.st.old_outboxes.len()
                        ));
                    }
                    self.st.old_outboxes.clear();
                    self.st.move_state = MoveState::Stable;
                }
            }
        }
        Ok(())
    }

    // ------------------------------------------- admin takeover (B5.4)

    /// First successor: after `T_SUCCESSOR` without the admin, commit
    /// (empty, own leaf update) in its outbox and start a new generation.
    pub fn try_takeover(&mut self, dht: &mut dyn Dht) -> Result<bool, PocError> {
        let first = self.st.successors.first().cloned().unwrap_or_default();
        if first != self.st.cik
            || dht.now().saturating_sub(self.st.last_admin_activity) < T_SUCCESSOR
        {
            return Ok(false);
        }
        // Only if the admin has not committed this epoch meanwhile.
        self.sync_control(dht)?;
        // The new generation's record first: if the host has none ready,
        // nothing has changed yet.
        let (control, owner) = dht.create()?;
        let group = self.group.as_mut().expect("member has a group");
        // §B5.4: the takeover commit removes the lost admin's leaf, so the
        // members do not wait for its new outbox until the grace period
        // ends; a returning device rejoins as a new member. (If that leaf
        // is already gone, the commit only refreshes our own.)
        let old_admin = self.st.admin_cik.clone();
        let leaf = group
            .members()
            .find(|m| wire::hex(&m.signature_key) == old_admin)
            .map(|m| m.index);
        let commit = match leaf {
            Some(leaf) => {
                let (commit, _, _) = group
                    .remove_members(&self.provider, &self.signer, &[leaf])
                    .map_err(mls)?;
                commit.to_bytes().map_err(mls)?
            }
            None => {
                let bundle = group
                    .self_update(&self.provider, &self.signer, LeafNodeParameters::default())
                    .map_err(mls)?;
                bundle.into_contents().0.to_bytes().map_err(mls)?
            }
        };
        self.write_outbox(dht, Kind::Mls, &commit)?;
        let group = self.group.as_mut().expect("member has a group");
        group.merge_pending_commit(&self.provider).map_err(mls)?;
        self.st.epoch = group.epoch().as_u64();
        self.epoch_changed();
        // New generation owned by the new admin.
        let gen = self.st.gen + 1;
        let takeover = self.encrypt(&AppMsg::Takeover {
            gen,
            control: control.clone(),
        })?;
        self.write_outbox(dht, Kind::Mls, &takeover)?;
        self.st.admin_cik = self.st.cik.clone();
        self.st.successors.retain(|s| *s != self.st.cik);
        self.st.control_owner = Some(owner);
        self.st.control = Some(control.clone());
        self.st.gen = gen;
        self.st.log_count = 0;
        self.st.log_hash = String::new();
        self.write_header(dht)?;
        self.st.move_state = MoveState::Moving { gen, control };
        Ok(true)
    }

    /// New admin after a handover (§B5.4): starts generation g + 1 (the old
    /// admin still owns `C_g`) and announces it with a `Takeover` in its
    /// own outbox, without a commit. Then a commit soon (`commit_due`), so
    /// members whose Updates the old admin never committed can send again.
    fn start_after_handover(&mut self, dht: &mut dyn Dht) -> Result<(), PocError> {
        if !self.st.handover_due
            || self.st.removed
            || self.st.move_state != MoveState::Stable
            || !self.is_admin()
        {
            return Ok(());
        }
        // The record first: if the host has none ready, nothing changed.
        let (control, owner) = dht.create()?;
        let gen = self.st.gen + 1;
        // Our own Update, if one waits, will never be committed by the old
        // admin; our next commit refreshes our leaf anyway.
        if self.my_update_pending() {
            let group = self.group.as_mut().expect("member has a group");
            group
                .clear_pending_proposals(self.provider.storage())
                .map_err(mls)?;
            self.st.my_proposals.clear();
        }
        let takeover = self.encrypt(&AppMsg::Takeover {
            gen,
            control: control.clone(),
        })?;
        self.write_outbox(dht, Kind::Mls, &takeover)?;
        self.st.control_owner = Some(owner);
        self.st.control = Some(control.clone());
        self.st.gen = gen;
        self.st.log_count = 0;
        self.st.log_hash = String::new();
        self.write_header(dht)?;
        self.st.move_state = MoveState::Moving { gen, control };
        self.st.handover_due = false;
        self.st.commit_due = true;
        self.st
            .events
            .push("now the admin: new generation started".into());
        Ok(())
    }

    // ----------------------------------------------------- retention (F7)

    /// Drops all past epoch secrets (after the 24 h retention window).
    pub fn expire_past_epochs(&mut self) -> Result<(), PocError> {
        if let Some(g) = self.group.as_mut() {
            g.delete_past_epoch_secrets(&self.provider, PastEpochDeletion::delete_all())
                .map_err(mls)?;
        }
        Ok(())
    }

    /// Tries to decrypt a raw MLS message (used to show that a removed
    /// member cannot read anything new).
    pub fn try_decrypt(&mut self, body: &[u8]) -> Option<Vec<u8>> {
        let msg = MlsMessageIn::tls_deserialize_exact(body).ok()?;
        let proto = msg.try_into_protocol_message().ok()?;
        let group = self.group.as_mut()?;
        match group
            .process_message(&self.provider, proto)
            .ok()?
            .into_content()
        {
            ProcessedMessageContent::ApplicationMessage(a) => Some(a.into_bytes()),
            _ => None,
        }
    }

    pub fn my_outbox(&self) -> Option<RecordId> {
        self.st.my_outbox.as_ref().map(|(o, _)| o.clone())
    }
}

/// Admin silence after which the first successor may take over (B5.4:
/// 14 days; ticks in the mock, 1 tick = 1 hour).
pub const T_SUCCESSOR: u64 = 14 * 24;
/// Old generation kept alive for members that were offline (30 days).
pub const GRACE: u64 = 30 * 24;

fn chain(prev: &str, value: &[u8]) -> String {
    let mut buf = prev.as_bytes().to_vec();
    buf.extend_from_slice(value);
    wire::sha256_hex(&buf)
}

fn chain_all(prev: &str, values: &[Vec<u8>]) -> String {
    values.iter().fold(prev.to_string(), |h, v| chain(&h, v))
}

/// Splits consecutive log values into whole messages: (subkeys, kind, body).
fn split_messages(values: &[Vec<u8>]) -> Result<Vec<(u32, Kind, Vec<u8>)>, wire::WireError> {
    let mut out = vec![];
    let mut i = 0;
    while i < values.len() {
        let c = wire::parse_chunk(&values[i])?;
        let n = c.total as usize;
        if c.index != 0 || i + n > values.len() {
            return Err(wire::WireError::Malformed("log chunks"));
        }
        let (kind, body) = wire::reassemble(&values[i..i + n])?;
        out.push((n as u32, kind, body));
        i += n;
    }
    Ok(out)
}

/// The sender's CIK, from its leaf's signature key in the current tree
/// (authoritative, unlike the free-form credential content).
fn sender_key(group: &MlsGroup, processed: &ProcessedMessage) -> String {
    match processed.sender() {
        Sender::Member(index) => group
            .members()
            .find(|m| m.index == *index)
            .map(|m| wire::hex(&m.signature_key))
            .unwrap_or_default(),
        _ => String::new(),
    }
}
