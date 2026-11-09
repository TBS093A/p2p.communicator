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
use openmls_traits::{random::OpenMlsRand, types::SignatureScheme, OpenMlsProvider};
use serde::{Deserialize, Serialize};

use crate::dht::{MockDht, RecordId};
use crate::provider::PocProvider;
use crate::wire::{self, AppMsg, ControlHeader, Kind, OutboxHead};

/// MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519 (0x0003).
pub const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519;

/// Out-of-order tolerance per sender (B12 F6: 100 skipped keys).
pub const OUT_OF_ORDER: u32 = 100;
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
    /// Writer secret of the request slot (subkeys 1..=4).
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
        if inv.slot.len() != 32 || inv.admin_cik.len() != 64 {
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
}

/// Welcome plus what the joiner needs to find the group, written by the
/// admin to the rendezvous record (subkeys 10..).
#[derive(Serialize, Deserialize)]
struct JoinAnswer {
    welcome: Vec<u8>,
    control: RecordId,
    gen: u64,
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
    pub fn create_group(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
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
        self.st.last_admin_activity = dht.now;
        let owner = self.random(32);
        let control = dht.create(&owner);
        self.st.control_owner = Some(owner);
        self.st.control = Some(control);
        self.write_header(dht)?;
        let (outbox, secret) = self.new_outbox(dht)?;
        self.st.my_outbox = Some((outbox.clone(), secret));
        let me = self.st.cik.clone();
        self.st.outboxes.insert(me, outbox);
        Ok(())
    }

    fn new_outbox(&self, dht: &mut MockDht) -> Result<(RecordId, Vec<u8>), PocError> {
        let secret = self.random(32);
        let id = dht.create(&secret);
        dht.set(&id, 0, &OutboxHead { count: 0 }.encode(), &secret)?;
        Ok((id, secret))
    }

    /// Admin: the successor list members will accept a takeover from.
    pub fn set_successors(&mut self, successors: Vec<String>) {
        self.st.successors = successors;
    }

    /// Admin: a one-time invite with its own rendezvous record.
    pub fn create_invite(&mut self, dht: &mut MockDht) -> Result<Invite, PocError> {
        let owner = self.random(32);
        let slot = self.random(32);
        let rendezvous = dht.create(&owner);
        for k in 1..=4 {
            dht.allow_subkey_writer(&rendezvous, &owner, k, &slot)?;
        }
        self.st.invites.insert(rendezvous.clone(), owner);
        Ok(Invite {
            rendezvous,
            slot,
            admin_cik: self.st.cik.clone(),
        })
    }

    /// Joiner: writes a KeyPackage to the invite's slot. `verified_admin`
    /// is the admin CIK compared out of band (B4 step 2); without a match no
    /// request is sent.
    pub fn request_join(
        &mut self,
        dht: &mut MockDht,
        invite: &Invite,
        verified_admin: &str,
    ) -> Result<usize, PocError> {
        if verified_admin != invite.admin_cik {
            return Err(PocError::Rejected(
                "admin key not verified out of band: no join request sent".into(),
            ));
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
        })
        .expect("request serializes");
        let chunks = wire::chunk(Kind::KeyPackage, &req);
        if chunks.len() > 4 {
            return Err(PocError::Rejected("join request too large".into()));
        }
        for (i, c) in chunks.iter().enumerate() {
            dht.set(&invite.rendezvous, 1 + i as u32, c, &invite.slot)?;
        }
        Ok(kp_bytes.len())
    }

    /// Admin: stages the Add for a pending join request (does not publish).
    pub fn stage_add(&mut self, dht: &mut MockDht, rendezvous: &RecordId) -> Result<(), PocError> {
        self.stage_add_many(dht, std::slice::from_ref(rendezvous))
    }

    /// Admin: one Add commit for several join requests (F17: one Welcome
    /// for many members).
    pub fn stage_add_many(
        &mut self,
        dht: &mut MockDht,
        rendezvous: &[RecordId],
    ) -> Result<(), PocError> {
        self.require_no_pending()?;
        let mut kps = vec![];
        let mut joiners = vec![];
        for r in rendezvous {
            let (kp, joiner) = self.read_join_request(dht, r)?;
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
        self.st.pending = Some(Pending {
            kind: PendingKind::Add {
                welcome: welcome.to_bytes().map_err(mls)?,
                joiners,
            },
            commit: commit.to_bytes().map_err(mls)?,
            at: self.st.log_count,
            hash_at: self.st.log_hash.clone(),
            phase: 0,
            followups: vec![],
        });
        Ok(())
    }

    fn read_join_request(
        &self,
        dht: &MockDht,
        rendezvous: &RecordId,
    ) -> Result<(KeyPackage, Joiner), PocError> {
        let owner = self
            .st
            .invites
            .get(rendezvous)
            .cloned()
            .ok_or_else(|| PocError::Rejected("unknown or used invite".into()))?;
        let mut values = vec![];
        let first = dht
            .get(rendezvous, 1)?
            .ok_or_else(|| PocError::Rejected("no join request yet".into()))?;
        let total = wire::parse_chunk(&first)
            .map_err(|e| PocError::Rejected(e.to_string()))?
            .total;
        values.push(first);
        for k in 2..=total as u32 {
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
        Ok((
            kp,
            Joiner {
                rendezvous: rendezvous.clone(),
                rendezvous_owner: owner,
                cik: joiner_cik,
                outbox: req.outbox,
            },
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
        Ok(())
    }

    /// Admin: stages the removal of `cik` and a move to a new generation.
    pub fn stage_remove(&mut self, dht: &mut MockDht, cik: &str) -> Result<(), PocError> {
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
        let next_owner = self.random(32);
        let next_control = dht.create(&next_owner);
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
        });
        Ok(())
    }

    /// Admin: commits the queued proposals (e.g. members' Updates, F13).
    pub fn stage_commit_proposals(&mut self) -> Result<(), PocError> {
        self.require_no_pending()?;
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
        });
        Ok(())
    }

    /// Admin: publishes the pending commit (all phases).
    pub fn publish_pending(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
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
    pub fn publish_step(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
        let Some(mut p) = self.st.pending.clone() else {
            return Ok(());
        };
        match p.phase {
            0 => {
                self.st.log_count = p.at;
                self.st.log_hash = p.hash_at.clone();
                self.append_log(dht, Kind::Mls, &p.commit)?;
                p.phase = 1;
            }
            1 => {
                let group = self.group.as_mut().expect("admin has a group");
                if group.pending_commit().is_some() {
                    group.merge_pending_commit(&self.provider).map_err(mls)?;
                }
                self.st.epoch = group.epoch().as_u64();
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
                    PendingKind::Proposals => vec![],
                };
                p.phase = 2;
            }
            _ => {
                // Positions right after the commit, same bytes every time.
                self.st.log_count = p.at;
                self.st.log_hash = p.hash_at.clone();
                self.append_log(dht, Kind::Mls, &p.commit)?;
                for f in &p.followups {
                    self.append_log(dht, Kind::Mls, f)?;
                }
                self.write_header(dht)?;
                match &p.kind {
                    PendingKind::Add { welcome, joiners } => {
                        let control = self.st.control.clone().expect("admin has control");
                        let answer = serde_json::to_vec(&JoinAnswer {
                            welcome: welcome.clone(),
                            control,
                            gen: self.st.gen,
                        })
                        .expect("answer serializes");
                        for j in joiners {
                            for (i, c) in wire::chunk(Kind::Welcome, &answer).iter().enumerate() {
                                dht.set(&j.rendezvous, 10 + i as u32, c, &j.rendezvous_owner)?;
                            }
                            // One-time invite.
                            self.st.invites.remove(&j.rendezvous);
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
                        self.append_log(dht, Kind::Mls, &p.commit)?;
                        self.write_header(dht)?;
                        self.st.move_state = MoveState::Moving {
                            gen,
                            control: next_control.clone(),
                        };
                    }
                    PendingKind::Proposals => {}
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
    pub fn publish_directory_now(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
        let msg = self.directory_message()?;
        self.append_log(dht, Kind::Mls, &msg)?;
        self.write_header(dht)
    }

    /// Test hook: the admin appends raw bytes to its log (duplicates and
    /// replays, F3/F4).
    pub fn append_raw_for_test(&mut self, dht: &mut MockDht, msg: &[u8]) -> Result<(), PocError> {
        self.append_log(dht, Kind::Mls, msg)?;
        self.write_header(dht)
    }

    fn append_log(&mut self, dht: &mut MockDht, kind: Kind, msg: &[u8]) -> Result<(), PocError> {
        let control = self.st.control.clone().expect("admin has control");
        let owner = self.st.control_owner.clone().expect("admin owns control");
        for c in wire::chunk(kind, msg) {
            self.st.log_count += 1;
            dht.set(&control, self.st.log_count, &c, &owner)?;
            self.st.log_hash = chain(&self.st.log_hash, &c);
            self.note_log_hash();
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
    pub fn rewrite_log_for_test(&mut self, dht: &mut MockDht, pos: u32) -> Result<(), PocError> {
        let control = self.st.control.clone().expect("admin has control");
        let owner = self.st.control_owner.clone().expect("admin owns control");
        let msg = self.directory_message()?;
        let chunks = wire::chunk(Kind::Mls, &msg);
        assert_eq!(chunks.len(), 1, "test rewrites a one-chunk entry");
        dht.set(&control, pos, &chunks[0], &owner)?;
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

    fn write_header(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
        let control = self.st.control.clone().expect("admin has control");
        let owner = self.st.control_owner.clone().expect("admin owns control");
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
    pub fn complete_join(&mut self, dht: &mut MockDht, invite: &Invite) -> Result<bool, PocError> {
        let Some(first) = dht.get(&invite.rendezvous, 10)? else {
            return Ok(false);
        };
        let total = wire::parse_chunk(&first)
            .map_err(|e| PocError::Rejected(e.to_string()))?
            .total;
        let mut values = vec![first];
        for k in 11..10 + total as u32 {
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
        let answer: JoinAnswer = serde_json::from_slice(&body)
            .map_err(|_| PocError::Rejected("malformed welcome".into()))?;
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
        self.st.last_admin_activity = dht.now;
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

    fn write_outbox(&mut self, dht: &mut MockDht, kind: Kind, msg: &[u8]) -> Result<(), PocError> {
        let (outbox, secret) = self
            .st
            .my_outbox
            .clone()
            .ok_or_else(|| PocError::Rejected("no outbox".into()))?;
        for c in wire::chunk(kind, msg) {
            self.st.my_count += 1;
            dht.set(&outbox, self.st.my_count, &c, &secret)?;
            self.st.sent.insert(self.st.my_count, c);
        }
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
    pub fn send_text(&mut self, dht: &mut MockDht, text: &str) -> Result<usize, PocError> {
        self.st.my_seq += 1;
        let msg = AppMsg::Text {
            id: wire::hex(&self.random(16)),
            seq: self.st.my_seq,
            text: text.into(),
            prev: self.st.my_prev.clone(),
            ctl: self.ctl(),
        };
        self.st.my_prev = wire::sha256_hex(&msg.encode());
        let bytes = self.encrypt(&msg)?;
        self.write_outbox(dht, Kind::Mls, &bytes)?;
        Ok(bytes.len())
    }

    /// Sends an Update proposal (fresh leaf key) for the admin to commit.
    pub fn propose_update(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
        let group = self
            .group
            .as_mut()
            .ok_or_else(|| PocError::Rejected("no group".into()))?;
        let (msg, _) = group
            .propose_self_update(&self.provider, &self.signer, LeafNodeParameters::default())
            .map_err(mls)?;
        let bytes = msg.to_bytes().map_err(mls)?;
        self.write_outbox(dht, Kind::Mls, &bytes)
    }

    /// Re-sends own outbox values the network lost (F16).
    fn repair_own_outbox(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
        let Some((outbox, secret)) = self.st.my_outbox.clone() else {
            return Ok(());
        };
        let mut repaired = false;
        for (k, v) in self.st.sent.clone() {
            if dht.get(&outbox, k)?.is_none() {
                dht.set(&outbox, k, &v, &secret)?;
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
    pub fn sync(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
        self.sync_with_move_steps(dht, 4)
    }

    /// Like [`Member::sync`], with at most `move_steps` steps of a pending
    /// generation move (tests restart the member between steps, F8).
    pub fn sync_with_move_steps(
        &mut self,
        dht: &mut MockDht,
        move_steps: usize,
    ) -> Result<(), PocError> {
        if self.group.is_none() {
            return Ok(());
        }
        self.repair_own_outbox(dht)?;
        if self.removed_stop() {
            return Ok(());
        }
        self.sync_outboxes(dht)?;
        self.sync_control(dht)?;
        self.sync_outboxes(dht)?;
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

    fn sync_control(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
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
    fn handle_control_entry(&mut self, dht: &mut MockDht, body: &[u8]) -> Result<bool, PocError> {
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
                self.st.last_admin_activity = dht.now;
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
                self.st.last_admin_activity = dht.now;
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
    fn sync_outboxes(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
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
        dht: &mut MockDht,
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
        // Retry earlier gaps first, then new subkeys.
        let mut starts: Vec<u32> = cur.missing.iter().copied().collect();
        let mut p = cur.next.max(1);
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
            let Some(first) = dht.get(outbox, s)? else {
                new_missing.insert(s);
                continue;
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
                match dht.get(outbox, k)? {
                    Some(v) => values.push(v),
                    None => complete = false,
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
        Ok(())
    }

    /// Returns false when the message has to be retried later (it belongs
    /// to an epoch whose commit we have not seen yet, F1).
    fn handle_outbox_message(
        &mut self,
        dht: &mut MockDht,
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
        let group = self.group.as_mut().expect("synced only with a group");
        let msg_epoch = proto.epoch().as_u64();
        let current = group.epoch().as_u64();
        let content_type = proto.content_type();
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
            self.st.last_admin_activity = dht.now;
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
                group
                    .store_pending_proposal(self.provider.storage(), *p)
                    .map_err(mls)?;
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                // Only a successor's takeover commit may come from an outbox
                // (B5.4), and only after the admin was silent long enough
                // and no admin commit exists for this epoch.
                let first_successor = self.st.successors.first().cloned().unwrap_or_default();
                let silent = dht.now.saturating_sub(self.st.last_admin_activity);
                if sender_cik == first_successor && silent >= T_SUCCESSOR {
                    group
                        .merge_staged_commit(&self.provider, *staged)
                        .map_err(mls)?;
                    self.st.epoch = group.epoch().as_u64();
                    self.st.admin_cik = sender_cik;
                    self.st.last_admin_activity = dht.now;
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
    pub fn step_move(&mut self, dht: &mut MockDht) -> Result<(), PocError> {
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
                    since: dht.now,
                };
            }
            MoveState::Announced { gen, since, .. } => {
                // Switch members whose announcement arrived.
                for (cik, (g, outbox)) in self.st.moved_to.clone() {
                    if g == gen && self.st.old_outboxes.remove(&cik).is_some() {
                        self.st.outboxes.insert(cik, outbox);
                    }
                }
                let expired = dht.now.saturating_sub(since) >= GRACE;
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
    pub fn try_takeover(&mut self, dht: &mut MockDht) -> Result<bool, PocError> {
        let first = self.st.successors.first().cloned().unwrap_or_default();
        if first != self.st.cik || dht.now.saturating_sub(self.st.last_admin_activity) < T_SUCCESSOR
        {
            return Ok(false);
        }
        // Only if the admin has not committed this epoch meanwhile.
        self.sync_control(dht)?;
        let group = self.group.as_mut().expect("member has a group");
        let bundle = group
            .self_update(&self.provider, &self.signer, LeafNodeParameters::default())
            .map_err(mls)?;
        let commit = bundle.into_contents().0.to_bytes().map_err(mls)?;
        self.write_outbox(dht, Kind::Mls, &commit)?;
        let group = self.group.as_mut().expect("member has a group");
        group.merge_pending_commit(&self.provider).map_err(mls)?;
        self.st.epoch = group.epoch().as_u64();
        // New generation owned by the new admin.
        let owner = self.random(32);
        let control = dht.create(&owner);
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
