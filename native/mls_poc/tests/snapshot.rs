//! The whole protocol driven the way the app will drive it (docs/V2_PLAN.md,
//! option C): every operation runs on a `SnapshotDht` filled by a host loop
//! (`snapshot::drive`), never on the DHT directly.

mod common;

use common::*;
use mls_poc::dht::{Dht, MockDht};
use mls_poc::member::{Member, MoveState};
use mls_poc::snapshot::{drive, SnapshotDht};

fn sync(dht: &mut MockDht, m: &mut Member) {
    drive(m, dht, |m, d| m.sync(d)).unwrap();
}

fn sync_everyone(dht: &mut MockDht, g: &mut [Member]) {
    for _ in 0..4 {
        for m in g.iter_mut() {
            sync(dht, m);
        }
    }
}

fn join_via_host(dht: &mut MockDht, g: &mut Vec<Member>, name: &str) {
    let mut m = Member::new(name);
    let invite = drive(&mut g[0], dht, |a, d| a.create_invite(d)).unwrap();
    let verified = invite.admin_cik.clone();
    drive(&mut m, dht, |m, d| m.request_join(d, &invite, &verified)).unwrap();
    drive(&mut g[0], dht, |a, d| a.stage_add(d, &invite.rendezvous)).unwrap();
    drive(&mut g[0], dht, |a, d| a.publish_pending(d)).unwrap();
    assert!(drive(&mut m, dht, |m, d| m.complete_join(d, &invite)).unwrap());
    g.push(m);
    sync_everyone(dht, g);
}

#[test]
fn whole_protocol_through_the_snapshot_host() {
    let mut dht = MockDht::new();
    let mut g = vec![Member::new("alice")];
    drive(&mut g[0], &mut dht, |m, d| m.create_group(d)).unwrap();
    join_via_host(&mut dht, &mut g, "bob");
    join_via_host(&mut dht, &mut g, "carol");
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);

    // Messages both ways; a dry run never sends twice.
    drive(&mut g[0], &mut dht, |m, d| m.send_text(d, "cześć")).unwrap();
    drive(&mut g[1], &mut dht, |m, d| m.send_text(d, "hej")).unwrap();
    sync_everyone(&mut dht, &mut g);
    assert_eq!(texts(&g[2]).iter().filter(|t| *t == "cześć").count(), 1);
    assert!(texts(&g[0]).contains(&"hej".to_string()));

    // Epoch rotation (Update proposal, admin commit).
    let epoch = g[0].st.epoch;
    drive(&mut g[1], &mut dht, |m, d| m.propose_update(d)).unwrap();
    sync_everyone(&mut dht, &mut g);
    g[0].stage_commit_proposals().unwrap();
    drive(&mut g[0], &mut dht, |m, d| m.publish_pending(d)).unwrap();
    sync_everyone(&mut dht, &mut g);
    assert_eq!(g[2].st.epoch, epoch + 1);
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);

    // Restart (state saved and restored), then still in the group.
    let saved = g[1].snapshot();
    g[1] = Member::restore(&saved).unwrap();

    // Removal: carol out, the rest move to a new generation.
    let carol = g[2].st.cik.clone();
    let gen = g[0].st.gen;
    drive(&mut g[0], &mut dht, |m, d| m.stage_remove(d, &carol)).unwrap();
    drive(&mut g[0], &mut dht, |m, d| m.publish_pending(d)).unwrap();
    for _ in 0..6 {
        sync(&mut dht, &mut g[0]);
        sync(&mut dht, &mut g[1]);
    }
    assert_eq!(g[1].st.gen, gen + 1);
    assert_eq!(g[1].st.move_state, MoveState::Stable);
    drive(&mut g[0], &mut dht, |m, d| m.send_text(d, "po usunięciu")).unwrap();
    for _ in 0..3 {
        sync(&mut dht, &mut g[1]);
        sync(&mut dht, &mut g[2]);
    }
    assert!(texts(&g[1]).contains(&"po usunięciu".to_string()));
    assert!(!texts(&g[2]).contains(&"po usunięciu".to_string()));
}

#[test]
fn a_missing_value_reads_as_not_yet_and_is_asked_for() {
    let mut dht = MockDht::new();
    let (rec, owner) = Dht::create(&mut dht).unwrap();
    dht.set(&rec, 3, b"x", &owner).unwrap();
    let mut snap = SnapshotDht::new(0);
    assert_eq!(snap.get(&rec, 3).unwrap(), None);
    assert_eq!(snap.needs(), vec![(rec.clone(), 3)]);
    snap.provide(&rec, 3, Some(b"x".to_vec()));
    assert_eq!(snap.get(&rec, 3).unwrap(), Some(b"x".to_vec()));
}

#[test]
fn creating_without_a_ready_record_changes_nothing() {
    let mut alice = Member::new("alice");
    let before = alice.snapshot();
    let mut snap = SnapshotDht::new(0); // no records provided
    assert!(alice.create_group(&mut snap).is_err());
    assert!(snap.writes().is_empty());
    assert_eq!(alice.snapshot(), before, "state must not change");
}
