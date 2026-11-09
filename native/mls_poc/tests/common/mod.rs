#![allow(dead_code)]

use mls_poc::dht::MockDht;
use mls_poc::member::Member;

/// A group: the first name is the admin, the others join one by one.
pub fn group(names: &[&str]) -> (MockDht, Vec<Member>) {
    let mut dht = MockDht::new();
    let mut members = vec![];
    let mut admin = Member::new(names[0]);
    admin.create_group(&mut dht).unwrap();
    members.push(admin);
    for name in &names[1..] {
        let m = join(&mut dht, &mut members, name);
        members.push(m);
    }
    sync_all(&mut dht, &mut members);
    (dht, members)
}

/// A new member joins through a fresh invite from `members[0]` (admin).
pub fn join(dht: &mut MockDht, members: &mut [Member], name: &str) -> Member {
    let mut m = Member::new(name);
    let invite = members[0].create_invite(dht).unwrap();
    let verified = invite.admin_cik.clone();
    m.request_join(dht, &invite, &verified).unwrap();
    members[0].stage_add(dht, &invite.rendezvous).unwrap();
    members[0].publish_pending(dht).unwrap();
    assert!(
        m.complete_join(dht, &invite).unwrap(),
        "welcome not visible"
    );
    sync_all(dht, members);
    m.sync(dht).unwrap();
    m
}

pub fn sync_all(dht: &mut MockDht, members: &mut [Member]) {
    for _ in 0..3 {
        for m in members.iter_mut() {
            m.sync(dht).unwrap();
        }
    }
}

pub fn texts(m: &Member) -> Vec<String> {
    m.st.inbox.iter().map(|r| r.text.clone()).collect()
}

pub fn has_event(m: &Member, needle: &str) -> bool {
    m.st.events.iter().any(|e| e.contains(needle))
}

/// All listed members are in the same epoch with the same key schedule.
pub fn assert_same_epoch(members: &[&Member]) {
    let auth = members[0].epoch_authenticator();
    for m in members {
        assert_eq!(m.st.epoch, members[0].st.epoch, "{} epoch", m.st.name);
        assert_eq!(m.epoch_authenticator(), auth, "{} key schedule", m.st.name);
    }
}

/// Deterministic pseudo-random bytes (xorshift64*).
pub struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    pub fn bytes(&mut self, max: usize) -> Vec<u8> {
        let n = (self.next() as usize) % (max + 1);
        (0..n).map(|_| self.next() as u8).collect()
    }
}
