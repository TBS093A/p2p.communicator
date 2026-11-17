//! docs/PROTOCOL.md B12: failure scenarios F1–F19 on the mock DHT.

mod common;

use common::*;
use mls_poc::dht::MAX_SUBKEY_BYTES;
use mls_poc::member::{
    Invite, Member, MoveState, GRACE, LOG_SUBKEYS, OUTBOX_RING, OUT_OF_ORDER, REQUEST_FIRST,
    T_SUCCESSOR,
};
use mls_poc::wire;

// F1: values not propagated yet are waited for, not lost.
#[test]
fn f01_dht_delay() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    dht.set_delay(3);
    g[0].send_text(&mut dht, "opóźniona").unwrap();
    g[1].sync(&mut dht).unwrap();
    assert!(texts(&g[1]).is_empty(), "visible too early");
    dht.tick(3);
    g[1].sync(&mut dht).unwrap();
    assert_eq!(texts(&g[1]), ["opóźniona"]);

    // A commit not visible yet: the epoch simply waits.
    let before = g[1].st.epoch;
    g[1].propose_update(&mut dht).unwrap();
    dht.tick(3);
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    // A message in the new epoch, visible before the commit (written later,
    // but the reader looks at outboxes first).
    g[0].send_text(&mut dht, "nowa epoka").unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(
        g[1].st.epoch, before,
        "commit applied before it was visible"
    );
    dht.tick(3);
    g[1].sync(&mut dht).unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(g[1].st.epoch, before + 1);
    assert!(
        texts(&g[1]).contains(&"nowa epoka".to_string()),
        "early message lost"
    );
}

// F2: admin offline: messages flow, proposals queue, membership frozen.
#[test]
fn f02_admin_offline() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let epoch = g[1].st.epoch;
    // Alice (admin) stops syncing.
    g[1].send_text(&mut dht, "od boba").unwrap();
    g[2].send_text(&mut dht, "od carol").unwrap();
    g[1].propose_update(&mut dht).unwrap();
    for _ in 0..3 {
        g[1].sync(&mut dht).unwrap();
        g[2].sync(&mut dht).unwrap();
    }
    assert!(texts(&g[1]).contains(&"od carol".to_string()));
    assert!(texts(&g[2]).contains(&"od boba".to_string()));
    assert_eq!(
        g[1].st.epoch, epoch,
        "membership must not change without the admin"
    );
    assert_eq!(g[2].st.epoch, epoch);
    // The admin returns and commits the queued proposal.
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    assert_eq!(g[1].st.epoch, epoch + 1);
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
}

// F3: the same commit delivered twice: the second copy is ignored.
#[test]
fn f03_duplicated_commit() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    g[1].propose_update(&mut dht).unwrap();
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    let commit = g[0].st.pending.as_ref().unwrap().commit.clone();
    g[0].publish_pending(&mut dht).unwrap();
    g[1].sync(&mut dht).unwrap();
    let epoch = g[1].st.epoch;
    g[0].append_raw_for_test(&mut dht, &commit).unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(g[1].st.epoch, epoch);
    assert!(has_event(&g[1], "old commit"), "{:?}", g[1].st.events);
    // Still in sync afterwards.
    g[0].send_text(&mut dht, "dalej działa").unwrap();
    g[1].sync(&mut dht).unwrap();
    assert!(texts(&g[1]).contains(&"dalej działa".to_string()));
}

// F4: an older commit replayed later is rejected by the epoch rule.
#[test]
fn f04_replayed_old_commit() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    let mut commits = vec![];
    for _ in 0..3 {
        g[1].propose_update(&mut dht).unwrap();
        g[0].sync(&mut dht).unwrap();
        g[0].stage_commit_proposals().unwrap();
        commits.push(g[0].st.pending.as_ref().unwrap().commit.clone());
        g[0].publish_pending(&mut dht).unwrap();
        g[1].sync(&mut dht).unwrap();
    }
    let epoch = g[1].st.epoch;
    g[0].append_raw_for_test(&mut dht, &commits[0]).unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(g[1].st.epoch, epoch);
    assert!(has_event(&g[1], "old commit"));
    assert_same_epoch(&[&g[0], &g[1]]);
}

// F5: a storage node serving an older control record is ignored.
#[test]
fn f05_rollback() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    g[1].propose_update(&mut dht).unwrap();
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    g[1].sync(&mut dht).unwrap();
    let (epoch, count) = (g[1].st.epoch, g[1].st.log_count);
    let control = g[1].st.control.clone().unwrap();
    dht.set_stale(&control, true);
    g[1].sync(&mut dht).unwrap();
    assert_eq!((g[1].st.epoch, g[1].st.log_count), (epoch, count));
    assert!(has_event(&g[1], "rollback"), "{:?}", g[1].st.events);
    // The node recovers: the member keeps going.
    dht.set_stale(&control, false);
    g[1].propose_update(&mut dht).unwrap();
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(g[1].st.epoch, epoch + 1);
}

// F6: out-of-order messages within an epoch; real gaps reported.
#[test]
fn f06_out_of_order() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    dht.set_delay(5);
    g[0].send_text(&mut dht, "pierwsza").unwrap();
    dht.set_delay(0);
    g[0].send_text(&mut dht, "druga").unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(texts(&g[1]), ["druga"]);
    assert_eq!(g[1].real_gaps(), 1, "the first message is still missing");
    dht.tick(5);
    g[1].sync(&mut dht).unwrap();
    assert_eq!(texts(&g[1]), ["druga", "pierwsza"]);
    assert_eq!(g[1].real_gaps(), 0, "nothing is missing any more");

    // Beyond the out-of-order window (100 skipped keys): undecryptable.
    dht.set_delay(5);
    g[0].send_text(&mut dht, "za stara").unwrap();
    dht.set_delay(0);
    for i in 0..OUT_OF_ORDER + 2 {
        g[0].send_text(&mut dht, &format!("m{i}")).unwrap();
    }
    g[1].sync(&mut dht).unwrap();
    let before = g[1].st.undecryptable;
    dht.tick(5);
    g[1].sync(&mut dht).unwrap();
    assert_eq!(g[1].st.undecryptable, before + 1);
    assert!(!texts(&g[1]).contains(&"za stara".to_string()));
}

// F7: a message from epoch e after e+1: inside the retention window it is
// read, after it "could not decrypt".
#[test]
fn f07_previous_epoch() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let rotate = |dht: &mut mls_poc::dht::MockDht, g: &mut Vec<Member>| {
        g[1].propose_update(dht).unwrap();
        g[0].sync(dht).unwrap();
        g[0].stage_commit_proposals().unwrap();
        g[0].publish_pending(dht).unwrap();
    };
    dht.set_delay(5);
    g[2].send_text(&mut dht, "z epoki e").unwrap();
    dht.set_delay(0);
    rotate(&mut dht, &mut g);
    g[1].sync(&mut dht).unwrap(); // bob reaches e+1 first
    dht.tick(5);
    g[1].sync(&mut dht).unwrap();
    assert!(
        texts(&g[1]).contains(&"z epoki e".to_string()),
        "within retention"
    );

    // Same, but bob dropped the past epoch secrets (24 h later).
    g[2].sync(&mut dht).unwrap();
    dht.set_delay(5);
    g[2].send_text(&mut dht, "za późno").unwrap();
    dht.set_delay(0);
    rotate(&mut dht, &mut g);
    g[1].sync(&mut dht).unwrap();
    g[1].expire_past_epochs().unwrap();
    let before = g[1].st.undecryptable;
    dht.tick(5);
    g[1].sync(&mut dht).unwrap();
    assert_eq!(g[1].st.undecryptable, before + 1);
    assert!(!texts(&g[1]).contains(&"za późno".to_string()));
}

/// Removal helper: admin removes `idx`, everyone else syncs.
fn remove(dht: &mut mls_poc::dht::MockDht, g: &mut [Member], idx: usize) {
    let cik = g[idx].st.cik.clone();
    g[0].stage_remove(dht, &cik).unwrap();
    g[0].publish_pending(dht).unwrap();
}

// F8: restart at every step of the move to a new generation.
#[test]
fn f08_restart_during_move() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    remove(&mut dht, &mut g, 2);
    // Bob processes the removal and the Move, then restarts after each step.
    g[1].sync_with_move_steps(&mut dht, 0).unwrap();
    assert!(matches!(g[1].st.move_state, MoveState::Moving { .. }));
    let mut bob = Member::restore(&g[1].snapshot()).unwrap();
    bob.step_move(&mut dht).unwrap();
    assert!(matches!(bob.st.move_state, MoveState::Created { .. }));
    let created_outbox = match &bob.st.move_state {
        MoveState::Created { outbox, .. } => outbox.clone(),
        _ => unreachable!(),
    };
    let mut bob = Member::restore(&bob.snapshot()).unwrap();
    bob.step_move(&mut dht).unwrap();
    assert!(matches!(bob.st.move_state, MoveState::Announced { .. }));
    assert_eq!(
        bob.my_outbox().unwrap(),
        created_outbox,
        "a second outbox was created"
    );
    // Third restart, then continue as the group's Bob.
    g[1] = Member::restore(&bob.snapshot()).unwrap();
    drop(bob);
    let mut moved = vec![g.remove(0), g.remove(0)];
    sync_all(&mut dht, &mut moved);
    assert_eq!(moved[1].st.move_state, MoveState::Stable);
    assert_eq!(moved[0].st.gen, 1);
    assert_eq!(moved[1].st.gen, 1);
    moved[1].send_text(&mut dht, "po przeprowadzce").unwrap();
    sync_all(&mut dht, &mut moved);
    assert!(texts(&moved[0]).contains(&"po przeprowadzce".to_string()));
}

// B5.3: a second removal while members are still moving: they follow the
// chain of Move pointers to g+2.
#[test]
fn f08b_second_removal_during_move() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol", "dave"]);
    // Dave is offline: the others stay in the "announced" step for gen 1.
    remove(&mut dht, &mut g, 1); // bob
    for _ in 0..2 {
        g[0].sync(&mut dht).unwrap();
        g[2].sync(&mut dht).unwrap();
    }
    assert!(matches!(
        g[2].st.move_state,
        MoveState::Announced { gen: 1, .. }
    ));
    remove(&mut dht, &mut g, 3); // dave, while the first move is unfinished
    for _ in 0..3 {
        g[0].sync(&mut dht).unwrap();
        g[2].sync(&mut dht).unwrap();
    }
    assert!(
        has_event(&g[2], "during an unfinished move"),
        "{:?}",
        g[2].st.events
    );
    assert_eq!(g[2].st.gen, 2);
    assert_eq!(g[2].st.move_state, MoveState::Stable);
    assert_same_epoch(&[&g[0], &g[2]]);
    g[0].send_text(&mut dht, "we dwoje").unwrap();
    g[2].sync(&mut dht).unwrap();
    assert!(texts(&g[2]).contains(&"we dwoje".to_string()));
}

// F9: the admin restarts mid-commit and republishes the same commit.
#[test]
fn f09_admin_restart_mid_commit() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    let mut carol = Member::new("carol");
    let invite = g[0].create_invite(&mut dht).unwrap();
    carol
        .request_join(&mut dht, &invite, &invite.admin_cik.clone())
        .unwrap();
    g[0].stage_add(&mut dht, &invite.rendezvous).unwrap();
    let commit = g[0].st.pending.as_ref().unwrap().commit.clone();
    // Crash after the commit is written and merged, before the header.
    g[0].publish_step(&mut dht).unwrap();
    g[0].publish_step(&mut dht).unwrap();
    let saved = g[0].snapshot();
    // ... and once more after everything was written, but restore the
    // earlier snapshot (the last state write was lost).
    g[0].publish_step(&mut dht).unwrap();
    g[1].sync(&mut dht).unwrap();
    let bob_epoch = g[1].st.epoch;
    let mut alice = Member::restore(&saved).unwrap();
    assert_eq!(
        alice.st.pending.as_ref().unwrap().commit,
        commit,
        "a different commit"
    );
    alice.publish_pending(&mut dht).unwrap();
    g[0] = alice;
    assert!(carol.complete_join(&mut dht, &invite).unwrap());
    g.push(carol);
    sync_all(&mut dht, &mut g);
    assert_eq!(g[1].st.epoch, bob_epoch, "bob saw two commits");
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
    assert!(!has_event(&g[1], "does not match"), "{:?}", g[1].st.events);
    g[2].send_text(&mut dht, "jestem").unwrap();
    sync_all(&mut dht, &mut g);
    assert!(texts(&g[1]).contains(&"jestem".to_string()));
}

// F10: a member offline during a removal catches up within the grace
// period; one back after it is left behind.
#[test]
fn f10_offline_during_removal() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol", "dave"]);
    // Dave is offline while Bob is removed.
    remove(&mut dht, &mut g, 1);
    for _ in 0..3 {
        g[0].sync(&mut dht).unwrap();
        g[2].sync(&mut dht).unwrap();
    }
    dht.tick(GRACE / 2);
    for _ in 0..3 {
        g[3].sync(&mut dht).unwrap();
        g[0].sync(&mut dht).unwrap();
        g[2].sync(&mut dht).unwrap();
    }
    for i in [0, 2, 3] {
        assert_eq!(g[i].st.gen, 1, "{} gen", g[i].st.name);
        assert_eq!(g[i].st.move_state, MoveState::Stable, "{}", g[i].st.name);
    }
    g[3].send_text(&mut dht, "wróciłem").unwrap();
    for _ in 0..2 {
        g[0].sync(&mut dht).unwrap();
        g[2].sync(&mut dht).unwrap();
    }
    assert!(texts(&g[2]).contains(&"wróciłem".to_string()));
}

#[test]
fn f10_offline_beyond_grace() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol", "dave"]);
    remove(&mut dht, &mut g, 1);
    for _ in 0..3 {
        g[0].sync(&mut dht).unwrap();
        g[2].sync(&mut dht).unwrap();
    }
    dht.tick(GRACE + 1);
    g[0].sync(&mut dht).unwrap();
    g[2].sync(&mut dht).unwrap();
    assert!(has_event(&g[2], "grace period over"));
    // Dave comes back too late: his announcement is no longer read.
    for _ in 0..3 {
        g[3].sync(&mut dht).unwrap();
    }
    g[3].send_text(&mut dht, "za późno wróciłem").unwrap();
    g[2].sync(&mut dht).unwrap();
    assert!(!texts(&g[2]).contains(&"za późno wróciłem".to_string()));
}

// F11: a lost device rejoins as a new identity; the admin removes the old.
#[test]
fn f11_member_device_lost() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let old_cik = g[2].st.cik.clone();
    let lost = g.remove(2); // Carol's phone is gone
    drop(lost);
    let carol2 = join(&mut dht, &mut g, "carol (new phone)");
    assert_ne!(carol2.st.cik, old_cik, "same identity reused");
    g.push(carol2);
    sync_all(&mut dht, &mut g);
    // Shown as a new identity: both keys are in the group until removal.
    assert!(g[1].members().contains(&old_cik));
    let cik = old_cik.clone();
    g[0].stage_remove(&mut dht, &cik).unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    assert!(!g[1].members().contains(&old_cik));
    g[0].send_text(&mut dht, "witaj z powrotem").unwrap();
    sync_all(&mut dht, &mut g);
    assert!(texts(&g[2]).contains(&"witaj z powrotem".to_string()));
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
}

/// alice (admin, successor: bob), bob, carol.
fn with_successor() -> (mls_poc::dht::MockDht, Vec<Member>) {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let bob = g[1].st.cik.clone();
    g[0].set_successors(vec![bob]);
    g[0].publish_directory_now(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    assert_eq!(g[2].st.successors, [g[1].st.cik.clone()]);
    (dht, g)
}

// F12: admin device lost: the first successor takes over after T_successor.
#[test]
fn f12_admin_device_lost() {
    let (mut dht, mut g) = with_successor();
    let mut alice = g.remove(0); // gone
                                 // Too early: nothing happens.
    dht.tick(T_SUCCESSOR / 2);
    assert!(!g[0].try_takeover(&mut dht).unwrap());
    dht.tick(T_SUCCESSOR);
    assert!(g[0].try_takeover(&mut dht).unwrap());
    sync_all(&mut dht, &mut g);
    assert!(
        has_event(&g[1], "takeover by the first successor accepted"),
        "{:?}",
        g[1].st.events
    );
    assert_eq!(g[1].st.admin_cik, g[0].st.cik);
    assert_eq!(g[1].st.gen, 1);
    assert_same_epoch(&[&g[0], &g[1]]);
    // §B5.4: the lost admin's leaf is gone, so nobody waits for it to move
    // (the move finished without the grace period, F14 lesson).
    let old_admin = alice.st.cik.clone();
    assert!(!g[0].members().contains(&old_admin));
    assert!(!g[1].members().contains(&old_admin));
    assert_eq!(g[1].st.move_state, MoveState::Stable);
    assert!(!has_event(&g[1], "grace period over"));
    g[1].send_text(&mut dht, "nowy admin").unwrap();
    sync_all(&mut dht, &mut g);
    assert!(texts(&g[0]).contains(&"nowy admin".to_string()));
    // The new admin can change membership: Dave joins.
    let dave = join(&mut dht, &mut g, "dave");
    g.push(dave);
    sync_all(&mut dht, &mut g);
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
    // The old admin's device must not matter any more.
    alice.sync(&mut dht).unwrap();
}

#[test]
fn f12_early_takeover_rejected() {
    let (mut dht, mut g) = with_successor();
    g[0].send_text(&mut dht, "admin żyje").unwrap();
    sync_all(&mut dht, &mut g);
    dht.tick(T_SUCCESSOR / 2);
    // Bob pretends the admin has been silent long enough; Carol knows better.
    g[1].st.last_admin_activity = 0;
    dht.tick(T_SUCCESSOR / 2 + 1);
    let carol_epoch = g[2].st.epoch;
    g[2].st.last_admin_activity = dht.now - 1;
    assert!(g[1].try_takeover(&mut dht).unwrap());
    g[2].sync(&mut dht).unwrap();
    assert!(
        has_event(&g[2], "commit from an outbox rejected"),
        "{:?}",
        g[2].st.events
    );
    assert_eq!(g[2].st.epoch, carol_epoch);
    assert_eq!(g[2].st.admin_cik, g[0].st.cik);
}

// F13: concurrent proposals from two members end in one epoch for all.
#[test]
fn f13_concurrent_proposals() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let epoch = g[0].st.epoch;
    g[1].propose_update(&mut dht).unwrap();
    g[2].propose_update(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    assert_eq!(g[1].st.epoch, epoch + 1, "one commit for both proposals");
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
}

// F14: the admin returns after a takeover: the moved members ignore it; a
// member that followed the old admin detects the fork and is re-added.
#[test]
fn f14_fork_after_takeover() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol", "dave"]);
    let bob = g[1].st.cik.clone();
    g[0].set_successors(vec![bob]);
    g[0].publish_directory_now(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    // Alice and Dave are offline; Bob takes over; Carol follows him.
    dht.tick(T_SUCCESSOR + 1);
    // Dave will see the old admin's commit before Bob's takeover.
    dht.set_delay(2);
    assert!(g[1].try_takeover(&mut dht).unwrap());
    dht.set_delay(0);
    // Alice returns and commits the old generation.
    g[3].propose_update(&mut dht).unwrap();
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    g[3].sync(&mut dht).unwrap(); // Dave follows Alice's commit
    dht.tick(2);
    for _ in 0..3 {
        g[2].sync(&mut dht).unwrap();
        g[1].sync(&mut dht).unwrap();
        g[3].sync(&mut dht).unwrap();
    }
    // Carol is on Bob's branch and does not watch the old records.
    assert_eq!(g[2].st.admin_cik, g[1].st.cik);
    assert_eq!(g[2].st.gen, 1);
    assert_same_epoch(&[&g[1], &g[2]]);
    // Dave notices the fork.
    assert!(g[3].st.fork_suspected, "{:?}", g[3].st.events);
    // Bob re-adds Dave as a new identity and removes the stale leaf.
    let old_dave = g[3].st.cik.clone();
    let mut moved = vec![g.remove(1), g.remove(1)]; // bob, carol
    let dave2 = join(&mut dht, &mut moved, "dave (rejoined)");
    moved.push(dave2);
    moved[0].stage_remove(&mut dht, &old_dave).unwrap();
    moved[0].publish_pending(&mut dht).unwrap();
    sync_all(&mut dht, &mut moved);
    assert_same_epoch(&[&moved[0], &moved[1], &moved[2]]);
    moved[2].send_text(&mut dht, "znowu razem").unwrap();
    sync_all(&mut dht, &mut moved);
    assert!(
        texts(&moved[1]).contains(&"znowu razem".to_string()),
        "carol: gen {} {:?} outboxes {:?}\ndave2: gen {} {:?} outbox {:?}\nevents {:?}",
        moved[1].st.gen,
        moved[1].st.move_state,
        moved[1].st.outboxes,
        moved[2].st.gen,
        moved[2].st.move_state,
        moved[2].my_outbox(),
        moved[1].st.events
    );
}

// F15: a removed member that keeps writing its old outbox is not read.
#[test]
fn f15_removed_member_keeps_writing() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let bob_outbox = g[1].my_outbox().unwrap();
    let old_bob_msg = dht.get(&bob_outbox, 0).unwrap();
    remove(&mut dht, &mut g, 1);
    sync_all(&mut dht, &mut g);
    assert!(g[1].st.removed);
    // Bob cannot even encrypt for the group any more...
    assert!(g[1].send_text(&mut dht, "jeszcze tu jestem").is_err());
    // ...and what lands in his old outbox is not read by anyone.
    let before = texts(&g[2]).len();
    let _ = old_bob_msg;
    sync_all(&mut dht, &mut g);
    assert_eq!(texts(&g[2]).len(), before);
    assert!(!g[2].st.outboxes.values().any(|o| *o == bob_outbox));
}

// F16: lost writes are detected and re-sent.
#[test]
fn f16_lost_writes() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    let outbox = g[0].my_outbox().unwrap();
    // The next value written to Alice's outbox (her first message) is lost.
    let next = dht
        .get(&outbox, 0)
        .unwrap()
        .map(|v| mls_poc::wire::OutboxHead::decode(&v).unwrap().count + 1);
    dht.lose_next_writes(&outbox, next.unwrap(), 1);
    g[0].send_text(&mut dht, "zgubiona").unwrap();
    g[0].send_text(&mut dht, "dotarła").unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(texts(&g[1]), ["dotarła"]);
    assert_eq!(g[1].real_gaps(), 1, "the chain shows a missing message");
    g[0].sync(&mut dht).unwrap(); // the writer notices and re-sends
    assert!(has_event(&g[0], "re-sent lost outbox values"));
    g[1].sync(&mut dht).unwrap();
    assert_eq!(texts(&g[1]), ["dotarła", "zgubiona"]);
    assert_eq!(g[1].real_gaps(), 0);
}

// F17: a Welcome for a large group spans several subkeys.
#[test]
fn f17_oversized_welcome() {
    let (mut dht, mut g) = group(&["alice"]);
    let n = 150;
    let mut joiners = vec![];
    let mut invites: Vec<Invite> = vec![];
    for i in 0..n {
        let mut m = Member::new(&format!("m{i}"));
        let inv = g[0].create_invite(&mut dht).unwrap();
        m.request_join(&mut dht, &inv, &inv.admin_cik.clone())
            .unwrap();
        joiners.push(m);
        invites.push(inv);
    }
    let rvs: Vec<_> = invites.iter().map(|i| i.rendezvous.clone()).collect();
    g[0].stage_add_many(&mut dht, &rvs).unwrap();
    let welcome_len = match &g[0].st.pending.as_ref().unwrap().kind {
        mls_poc::member::PendingKind::Add { welcome, .. } => welcome.len(),
        _ => unreachable!(),
    };
    let commit_len = g[0].st.pending.as_ref().unwrap().commit.len();
    println!(
        "Welcome for {} members: {welcome_len} B; commit {commit_len} B",
        n + 1
    );
    assert!(
        welcome_len > MAX_SUBKEY_BYTES,
        "pick a larger group to test chunking"
    );
    g[0].publish_pending(&mut dht).unwrap();
    assert!(dht.largest_value <= MAX_SUBKEY_BYTES);
    for (m, inv) in joiners.iter_mut().zip(&invites).take(3) {
        assert!(m.complete_join(&mut dht, inv).unwrap());
    }
    assert_eq!(joiners[0].epoch_authenticator(), g[0].epoch_authenticator());
    assert_eq!(joiners[2].members().len(), n + 1);
}

// F18: malformed data never crashes a parser or changes state.
#[test]
fn f18_fuzz_parsers() {
    let mut rng = Rng(0x5eed_1234_abcd_0001);
    for _ in 0..20_000 {
        let b = rng.bytes(300);
        let _ = wire::ControlHeader::decode(&b);
        let _ = wire::OutboxHead::decode(&b);
        let _ = wire::parse_chunk(&b);
        let _ = wire::reassemble(&[b.clone(), rng.bytes(40)]);
        let _ = wire::AppMsg::decode(&b);
        let _ = Invite::decode(&String::from_utf8_lossy(&b));
        let _ = Member::restore(&b);
        // Valid chunk framing with random contents.
        let mut framed = b"P2\x01\x00\x01\x00\x00".to_vec();
        framed.extend(rng.bytes(200));
        let _ = wire::reassemble(&[framed]);
    }
}

#[test]
fn f18_garbage_in_records() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    let mut rng = Rng(42);
    let control = g[1].st.control.clone().unwrap();
    let outbox = g[0].my_outbox().unwrap();
    let (epoch, count) = (g[1].st.epoch, g[1].st.log_count);
    for i in 0..300 {
        let junk = rng.bytes(500);
        match i % 5 {
            0 => dht.inject(&control, 0, &junk),
            1 => {
                // A well-formed header pointing at a garbage entry whose hash
                // chain is right (a node can compute it): still rejected.
                let entry = junk.clone();
                let next = count + 1;
                dht.inject(&control, next, &entry);
                let mut h = g[1].st.log_hash.clone().into_bytes();
                h.extend_from_slice(&entry);
                let header = wire::ControlHeader {
                    v: 2,
                    gen: 0,
                    epoch,
                    log_count: next,
                    prev: wire::sha256_hex(&h),
                };
                dht.inject(&control, 0, &header.encode());
            }
            2 => dht.inject(&outbox, 0, &junk),
            3 => dht.inject(&outbox, 1 + (i % 7) as u32, &junk),
            _ => {
                let mut framed = b"P2\x01\x00\x01\x00\x00".to_vec();
                framed.extend(junk);
                dht.inject(&outbox, 1, &framed);
            }
        }
        g[1].sync(&mut dht).unwrap();
        assert_eq!(
            (g[1].st.epoch, g[1].st.log_count),
            (epoch, count),
            "state changed at {i}"
        );
    }
    // Real writes still go through afterwards.
    g[1].propose_update(&mut dht).unwrap();
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(g[1].st.epoch, epoch + 1);
}

#[test]
fn f18_garbage_join_request() {
    let (mut dht, mut g) = group(&["alice"]);
    let mut rng = Rng(7);
    for _ in 0..200 {
        let invite = g[0].create_invite(&mut dht).unwrap();
        let junk = rng.bytes(2000);
        let _ = dht.set(&invite.rendezvous, REQUEST_FIRST, &junk, &invite.slot);
        assert!(g[0].stage_add(&mut dht, &invite.rendezvous).is_err());
        assert!(g[0].st.pending.is_none());
    }
    // An unverified admin key: no request is sent at all.
    let invite = g[0].create_invite(&mut dht).unwrap();
    let mut eve = Member::new("eve");
    assert!(eve
        .request_join(&mut dht, &invite, "00".repeat(32).as_str())
        .is_err());
    assert!(dht
        .get(&invite.rendezvous, REQUEST_FIRST)
        .unwrap()
        .is_none());
}

// F19: the admin rewrites a log position after some members read it. Each
// member's log is self-consistent, so only comparing `ctl` in messages
// reveals it (B5.2 r6); afterwards no further commit is accepted.
#[test]
fn f19_diverging_histories() {
    let (mut dht, mut g) = group(&["admin", "alice", "bob"]);
    // Healthy group: matching `ctl`, no alarm.
    g[1].send_text(&mut dht, "zgodnie").unwrap();
    sync_all(&mut dht, &mut g);
    assert!(g.iter().all(|m| !m.st.history_diverged), "false alarm");

    // Carol joins; Alice reads the commit and the Directory after it.
    let mut carol = Member::new("carol");
    let invite = g[0].create_invite(&mut dht).unwrap();
    let verified = invite.admin_cik.clone();
    carol.request_join(&mut dht, &invite, &verified).unwrap();
    g[0].stage_add(&mut dht, &invite.rendezvous).unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    g[1].sync(&mut dht).unwrap();
    let pos = g[0].st.log_count;
    assert_eq!(g[1].st.log_count, pos);

    // The admin equivocates: the Directory at `pos` gets different bytes
    // and the header a matching chain. Bob reads only the new version.
    g[0].rewrite_log_for_test(&mut dht, pos).unwrap();
    g[2].sync(&mut dht).unwrap();
    assert_eq!(g[2].st.log_count, pos, "bob accepts a self-consistent log");
    assert_ne!(g[1].st.log_hash, g[2].st.log_hash);
    assert!(
        !g[2].st.history_diverged,
        "not detectable from the log alone"
    );

    // Alice's next message carries her `ctl`: Bob detects the divergence,
    // and Alice detects it from Bob's.
    g[1].send_text(&mut dht, "mój stan").unwrap();
    g[2].send_text(&mut dht, "a mój inny").unwrap();
    g[1].sync(&mut dht).unwrap();
    g[2].sync(&mut dht).unwrap();
    assert!(g[2].st.history_diverged);
    assert!(g[1].st.history_diverged);
    assert!(has_event(&g[2], "group history differs"));
    assert!(
        texts(&g[2]).contains(&"mój stan".to_string()),
        "messages still shown"
    );

    // No further commit is accepted by a member that saw the divergence.
    let epoch = g[2].st.epoch;
    g[0].propose_update(&mut dht).unwrap();
    g[0].sync(&mut dht).unwrap();
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    assert_eq!(g[0].st.epoch, epoch + 1, "the admin did commit");
    for _ in 0..3 {
        g[2].sync(&mut dht).unwrap();
    }
    assert_eq!(g[2].st.epoch, epoch, "commit accepted after divergence");
}

// F20: the control log fills up; the group moves to a new generation
// without removing anyone, and a member offline meanwhile catches up.
#[test]
fn f20_full_log_moves_to_a_new_generation() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let gen = g[0].st.gen;
    // Carol goes offline; Updates fill the log until the admin must rotate.
    // Each commit takes three log entries: the copied Update, the commit
    // and the Directory (§B5.1).
    let mut commits = 0;
    while !g[0].needs_rotation() {
        g[1].propose_update(&mut dht).unwrap();
        g[0].sync(&mut dht).unwrap();
        if g[0].needs_rotation() {
            break; // the copy no longer fits with the reserve
        }
        g[0].stage_commit_proposals().unwrap();
        g[0].publish_pending(&mut dht).unwrap();
        g[1].sync(&mut dht).unwrap();
        commits += 1;
        assert!(commits < 40, "never asked to rotate");
    }
    assert!(g[0].st.log_count <= LOG_SUBKEYS);
    // Nothing more fits: committing is refused until the group rotates.
    if !g[1].my_update_pending() {
        g[1].propose_update(&mut dht).unwrap();
        g[0].sync(&mut dht).unwrap();
    }
    assert!(g[0].stage_commit_proposals().is_err());

    g[0].stage_rotate(&mut dht).unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    for _ in 0..4 {
        g[0].sync(&mut dht).unwrap();
        g[1].sync(&mut dht).unwrap();
    }
    // Bob is in the new generation; he stays "announced" (still reading the
    // old outboxes too) until Carol announces or the grace period ends.
    assert_eq!(g[1].st.gen, gen + 1);
    assert!(matches!(g[1].st.move_state, MoveState::Announced { .. }));
    assert!(g[0].st.log_count <= 1, "a fresh log");
    // The new generation works: messages.
    g[0].send_text(&mut dht, "nowa generacja").unwrap();
    for _ in 0..3 {
        g[1].sync(&mut dht).unwrap();
    }
    assert!(texts(&g[1]).contains(&"nowa generacja".to_string()));

    // Carol comes back: catches up commit by commit (with proposals by
    // reference one epoch per round; by value, phase 3, is faster), follows
    // the Move, announces, everyone settles.
    for _ in 0..60 {
        for m in g.iter_mut() {
            m.sync(&mut dht).unwrap();
        }
        if g.iter().all(|m| m.st.move_state == MoveState::Stable) {
            break;
        }
    }
    assert_eq!(
        g[2].st.gen,
        gen + 1,
        "carol: epoch {} log {} events {:?}",
        g[2].st.epoch,
        g[2].st.log_count,
        g[2].st.events
    );
    for m in &g {
        assert_eq!(m.st.move_state, MoveState::Stable, "{}", m.st.name);
    }
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
    assert!(texts(&g[2]).contains(&"nowa generacja".to_string()));
    // And commits work again in the fresh log.
    g[1].propose_update(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
}

// F21: a sender's outbox ring wrapped while a member was offline: the
// overwritten messages are a visible gap, the rest is read normally.
#[test]
fn f21_outbox_ring_wrapped_is_a_visible_gap() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    let extra = 10;
    for i in 0..OUTBOX_RING + extra {
        g[0].send_text(&mut dht, &format!("m{i}")).unwrap();
    }
    g[1].sync(&mut dht).unwrap();
    let got = texts(&g[1]);
    assert_eq!(g[1].st.lost_messages, extra);
    assert!(has_event(&g[1], "no longer available"));
    assert_eq!(got.len(), OUTBOX_RING as usize);
    assert_eq!(got.first().unwrap(), &format!("m{extra}"));
    assert_eq!(
        got.last().unwrap(),
        &format!("m{}", OUTBOX_RING + extra - 1)
    );
    // Within the ring nothing is lost, and it keeps working past the wrap.
    g[0].send_text(&mut dht, "dalej").unwrap();
    g[1].sync(&mut dht).unwrap();
    assert!(texts(&g[1]).contains(&"dalej".to_string()));
    assert_eq!(g[1].st.lost_messages, extra);
}

// F22: a message over the 4096-byte bucket is refused before anything
// changes or is written.
#[test]
fn f22_oversized_message_is_refused() {
    let (mut dht, mut g) = group(&["alice", "bob"]);
    let before = g[0].snapshot();
    let writes = dht.writes;
    let long = "ż".repeat(3000); // 6000 bytes of UTF-8
    assert!(g[0].send_text(&mut dht, &long).is_err());
    assert_eq!(dht.writes, writes, "nothing written");
    assert_eq!(g[0].snapshot(), before, "nothing changed");
    // Just under the limit still goes.
    g[0].send_text(&mut dht, &"a".repeat(3500)).unwrap();
    g[1].sync(&mut dht).unwrap();
    assert_eq!(texts(&g[1]).len(), 1);
}

// F23: members never take Update proposals from outboxes; the admin copies
// each into the log before its commit, so a member that never saw the
// proposal (offline, or the outbox lost it) applies the commit from the log
// alone, and nobody but the proposer waits for the commit to send again.
#[test]
fn f23_update_proposals_reach_members_through_the_log() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let epoch = g[0].st.epoch;
    g[1].propose_update(&mut dht).unwrap();
    assert!(g[1].my_update_pending());
    sync_all(&mut dht, &mut g);
    // Carol did not take Bob's proposal, so she can still send.
    assert_eq!(g[2].pending_proposals(), 0);
    g[2].send_text(&mut dht, "nadal piszę").unwrap();
    assert_eq!(g[0].pending_proposals(), 1, "the admin took it");

    // Carol goes offline; Bob's outbox loses the proposal for everyone
    // after the admin read it (simulated: the admin commits right away).
    let before = g[0].st.log_count;
    g[0].stage_commit_proposals().unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    assert_eq!(
        g[0].st.log_count,
        before + 3,
        "copy, commit and directory in the log"
    );
    g[1].sync(&mut dht).unwrap();
    assert!(
        !g[1].my_update_pending(),
        "own copy skipped, commit applied"
    );
    assert_eq!(g[1].st.epoch, epoch + 1);
    g[1].send_text(&mut dht, "znowu mogę").unwrap();

    // More rounds while Carol is away; she catches up from the log alone.
    for _ in 0..2 {
        g[1].propose_update(&mut dht).unwrap();
        g[0].sync(&mut dht).unwrap();
        g[0].stage_commit_proposals().unwrap();
        g[0].publish_pending(&mut dht).unwrap();
        g[1].sync(&mut dht).unwrap();
    }
    g[2].sync(&mut dht).unwrap();
    assert_eq!(g[2].st.epoch, epoch + 3, "{:?}", g[2].st.events);
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
    assert!(!has_event(&g[2], "not applicable"), "{:?}", g[2].st.events);
    g[1].send_text(&mut dht, "po wszystkim").unwrap();
    sync_all(&mut dht, &mut g);
    // ("znowu mogę" is two epochs back for Carol: unreadable, as in F7.)
    assert!(texts(&g[2]).contains(&"po wszystkim".to_string()));
    assert!(texts(&g[0]).contains(&"znowu mogę".to_string()));
    assert!(texts(&g[1]).contains(&"nadal piszę".to_string()));
}

// F24: the admin hands over to a member who is offline: messages keep
// flowing and membership is frozen; when the new admin comes online it
// starts g + 1 and everyone follows, including a member that reads the
// new admin's Takeover before the AdminTransfer in the log.
#[test]
fn f24_handover_to_an_offline_member() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol", "dave"]);
    let (gen, epoch) = (g[0].st.gen, g[0].st.epoch);
    let bob = g[1].st.cik.clone();
    // A handover only goes to another current member.
    assert!(g[0].stage_handover("00".repeat(32).as_str()).is_err());
    let alice = g[0].st.cik.clone();
    assert!(g[0].stage_handover(&alice).is_err());
    g[0].stage_handover(&bob).unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    assert!(!g[0].is_admin());
    // Carol reads it; Bob and Dave are offline.
    g[2].sync(&mut dht).unwrap();
    assert_eq!(g[2].st.admin_cik, bob);
    // Messages flow, membership is frozen: the old admin commits nothing.
    g[0].send_text(&mut dht, "już nie admin").unwrap();
    g[2].send_text(&mut dht, "ok").unwrap();
    g[0].sync(&mut dht).unwrap();
    g[2].sync(&mut dht).unwrap();
    assert!(texts(&g[2]).contains(&"już nie admin".to_string()));
    assert!(texts(&g[0]).contains(&"ok".to_string()));
    assert!(g[0].stage_commit_proposals().is_err());
    assert_eq!(g[2].st.epoch, epoch);

    // Bob comes online: he becomes the admin and starts g + 1.
    g[1].sync(&mut dht).unwrap();
    assert!(g[1].is_admin());
    assert_eq!(g[1].st.gen, gen + 1);
    assert!(g[1].st.commit_due);
    // Dave reads Bob's Takeover (outboxes first) before the AdminTransfer.
    g[3].sync(&mut dht).unwrap();
    assert_eq!(g[3].st.admin_cik, bob);
    assert_ne!(
        g[3].st.move_state,
        MoveState::Stable,
        "{:?}",
        g[3].st.events
    );
    for _ in 0..4 {
        sync_all(&mut dht, &mut g);
    }
    for m in &g {
        assert_eq!(m.st.gen, gen + 1, "{}: {:?}", m.st.name, m.st.events);
        assert_eq!(m.st.admin_cik, bob, "{}", m.st.name);
        assert_eq!(m.st.move_state, MoveState::Stable, "{}", m.st.name);
    }
    // The new admin commits (commit_due) and everyone applies it.
    g[1].stage_commit_proposals().unwrap();
    g[1].publish_pending(&mut dht).unwrap();
    assert!(!g[1].st.commit_due);
    sync_all(&mut dht, &mut g);
    assert_eq!(g[0].st.epoch, epoch + 1);
    assert_same_epoch(&[&g[0], &g[1], &g[2], &g[3]]);
    g[3].send_text(&mut dht, "nowy admin").unwrap();
    sync_all(&mut dht, &mut g);
    assert!(texts(&g[0]).contains(&"nowy admin".to_string()));
}

// F24, the member's view: an Update proposed before the handover is never
// committed (the old admin no longer commits, the new one never took it);
// the proposer drops it when it moves, so it is not blocked from sending,
// and proposes again in the new generation.
#[test]
fn f24_update_pending_across_a_handover() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let bob = g[1].st.cik.clone();
    g[2].propose_update(&mut dht).unwrap();
    assert!(g[2].send_text(&mut dht, "zablokowana").is_err(), "MLS rule");
    // The admin hands over before reading Carol's proposal.
    g[0].stage_handover(&bob).unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    for _ in 0..4 {
        sync_all(&mut dht, &mut g);
    }
    assert!(g[1].is_admin());
    assert!(!g[2].my_update_pending());
    assert!(has_event(&g[2], "own update not committed"));
    g[2].send_text(&mut dht, "odblokowana").unwrap();
    // Proposed again, committed by the new admin through the new log.
    g[2].propose_update(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    assert_eq!(g[1].pending_proposals(), 1);
    g[1].stage_commit_proposals().unwrap();
    g[1].publish_pending(&mut dht).unwrap();
    sync_all(&mut dht, &mut g);
    assert!(!g[2].my_update_pending());
    assert!(texts(&g[0]).contains(&"odblokowana".to_string()));
    assert_same_epoch(&[&g[0], &g[1], &g[2]]);
}

// F25: a DM invite started from a shared group (§B10) admits only the
// member it was meant for: another member who read it, with no proof, its
// own proof, or a proof claiming to be the recipient, is refused, and the
// invite stays open until the recipient joins with a fresh identity.
#[test]
fn f25_dm_invite_admits_only_the_invited_member() {
    let (mut dht, mut g) = group(&["alice", "bob", "carol"]);
    let bob_g = g[1].st.cik.clone();
    let mut alice_dm = Member::new("alice (DM)");
    alice_dm.create_group(&mut dht).unwrap();
    // Not a key: refused before anything is created.
    assert!(alice_dm.create_invite_for(&mut dht, Some("xyz")).is_err());
    let invite = alice_dm.create_invite_for(&mut dht, Some(&bob_g)).unwrap();
    let rv = invite.rendezvous.clone();
    let admin = invite.admin_cik.clone();

    // Carol read the invite in the group and tries it three ways.
    let mut carol_dm = Member::new("carol (DM)");
    let carol_cik = carol_dm.st.cik.clone();
    let own = g[2].sign_dm_join(&rv, &carol_cik).unwrap();
    let mut forged = own.clone();
    forged.cik = bob_g.clone(); // claims to be Bob, signed by Carol
    for proof in [None, Some(own), Some(forged)] {
        carol_dm
            .request_join_with(&mut dht, &invite, &admin, proof)
            .unwrap();
        let err = alice_dm.stage_add(&mut dht, &rv).unwrap_err();
        assert!(
            err.to_string().contains("not from the invited member"),
            "{err}"
        );
        assert!(alice_dm.st.pending.is_none());
    }
    // Bob's proof for a different new identity does not fit Carol's either.
    let stolen = g[1].sign_dm_join(&rv, "00".repeat(32).as_str()).unwrap();
    carol_dm
        .request_join_with(&mut dht, &invite, &admin, Some(stolen))
        .unwrap();
    assert!(alice_dm.stage_add(&mut dht, &rv).is_err());

    // Bob joins with a fresh identity and the proof from the group.
    let mut bob_dm = Member::new("bob (DM)");
    assert_ne!(bob_dm.st.cik, bob_g, "a new identity for the DM");
    let proof = g[1].sign_dm_join(&rv, &bob_dm.st.cik).unwrap();
    bob_dm
        .request_join_with(&mut dht, &invite, &admin, Some(proof))
        .unwrap();
    alice_dm.stage_add(&mut dht, &rv).unwrap();
    alice_dm.publish_pending(&mut dht).unwrap();
    assert!(bob_dm.complete_join(&mut dht, &invite).unwrap());
    let mut dm = vec![alice_dm, bob_dm];
    sync_all(&mut dht, &mut dm);
    assert_eq!(dm[0].members().len(), 2);
    dm[1].send_text(&mut dht, "prywatnie").unwrap();
    sync_all(&mut dht, &mut dm);
    assert!(texts(&dm[0]).contains(&"prywatnie".to_string()));
    // Used once: a second request is refused.
    assert!(dm[0].stage_add(&mut dht, &rv).is_err());
    // Carol never got in.
    assert!(carol_dm.group().is_none());
}
