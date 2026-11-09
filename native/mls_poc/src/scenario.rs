//! The minimal scenario of docs/PROTOCOL.md B13, with measurements. Run by
//! the Rust tests and, through FFI, by the Flutter test.

use std::time::Instant;

use serde::Serialize;

use crate::dht::{MockDht, MAX_SUBKEY_BYTES};
use crate::member::{Member, PendingKind};

#[derive(Debug, Default, Serialize)]
pub struct Report {
    pub ok: bool,
    pub ciphersuite: &'static str,
    pub steps: Vec<Step>,
    /// Bytes of each MLS object.
    pub sizes: Vec<(String, usize)>,
    pub subkey_limit: usize,
    /// Milliseconds per operation (on the machine that ran it).
    pub timings_ms: Vec<(String, f64)>,
    pub dht_writes: u64,
}

#[derive(Debug, Serialize)]
pub struct Step {
    pub name: String,
    pub ok: bool,
    pub detail: String,
}

impl Report {
    fn step(&mut self, name: &str, ok: bool, detail: impl Into<String>) {
        self.steps.push(Step {
            name: name.into(),
            ok,
            detail: detail.into(),
        });
    }

    fn time<T>(&mut self, name: &str, f: impl FnOnce() -> T) -> T {
        let t = Instant::now();
        let out = f();
        self.timings_ms
            .push((name.into(), t.elapsed().as_secs_f64() * 1000.0));
        out
    }
}

fn pending_size(m: &Member) -> (usize, usize) {
    match &m.st.pending {
        Some(p) => match &p.kind {
            PendingKind::Add { welcome, .. } => (p.commit.len(), welcome.len()),
            _ => (p.commit.len(), 0),
        },
        None => (0, 0),
    }
}

/// Two identities: create, join, messages, epoch rotation, restart,
/// removal. Never panics; failures are reported per step.
pub fn run_minimal() -> Report {
    let mut r = Report {
        ciphersuite: "MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519 (0x0003)",
        subkey_limit: MAX_SUBKEY_BYTES,
        ..Default::default()
    };
    match run_inner(&mut r) {
        Ok(()) => {}
        Err(e) => r.step("scenario", false, e),
    }
    r.ok = !r.steps.is_empty() && r.steps.iter().all(|s| s.ok);
    r
}

fn run_inner(r: &mut Report) -> Result<(), String> {
    let e = |x: crate::member::PocError| x.to_string();
    let mut dht = MockDht::new();

    // 1. Two independent identities.
    let mut alice = r.time("identity", || Member::new("Alice"));
    let mut bob = Member::new("Bob");
    r.step(
        "two independent identities",
        alice.st.cik != bob.st.cik,
        format!("CIK {}… / {}…", &alice.st.cik[..8], &bob.st.cik[..8]),
    );

    // 2. Group.
    r.time("create group", || alice.create_group(&mut dht))
        .map_err(e)?;
    r.step(
        "create group",
        alice.group().is_some(),
        "Alice is admin, epoch 0",
    );

    // 3. Join via KeyPackage / Welcome.
    let invite = alice.create_invite(&mut dht).map_err(e)?;
    let verified = invite.admin_cik.clone(); // compared out of band
    let kp = r
        .time("key package", || {
            bob.request_join(&mut dht, &invite, &verified)
        })
        .map_err(e)?;
    r.sizes.push(("KeyPackage".into(), kp));
    r.time("commit Add", || {
        alice.stage_add(&mut dht, &invite.rendezvous)
    })
    .map_err(e)?;
    let (add, welcome) = pending_size(&alice);
    r.sizes.push(("Commit (Add)".into(), add));
    r.sizes.push(("Welcome (2 members)".into(), welcome));
    alice.publish_pending(&mut dht).map_err(e)?;
    let joined = r
        .time("process Welcome", || bob.complete_join(&mut dht, &invite))
        .map_err(e)?;
    bob.sync(&mut dht).map_err(e)?;
    let same = alice.epoch_authenticator() == bob.epoch_authenticator();
    r.step(
        "second member joins",
        joined && same && bob.members().len() == 2,
        format!(
            "epoch {} on both, same epoch authenticator: {same}",
            bob.st.epoch
        ),
    );

    // 4. Encrypted messages both ways.
    let size = r
        .time("encrypt message", || {
            alice.send_text(&mut dht, "Cześć Bob!")
        })
        .map_err(e)?;
    r.sizes
        .push(("Application message (10 chars, padded)".into(), size));
    r.time("sync + decrypt", || bob.sync(&mut dht)).map_err(e)?;
    bob.send_text(&mut dht, "Cześć Alice!").map_err(e)?;
    alice.sync(&mut dht).map_err(e)?;
    let ok = bob.st.inbox.iter().any(|m| m.text == "Cześć Bob!")
        && alice.st.inbox.iter().any(|m| m.text == "Cześć Alice!");
    r.step(
        "encrypted messages both ways",
        ok,
        "decrypted by the other side",
    );

    // 5. Epoch rotation (Update proposal committed by the admin).
    let before = bob.st.epoch;
    bob.propose_update(&mut dht).map_err(e)?;
    alice.sync(&mut dht).map_err(e)?;
    r.time("commit Update", || alice.stage_commit_proposals())
        .map_err(e)?;
    r.sizes
        .push(("Commit (Update)".into(), pending_size(&alice).0));
    alice.publish_pending(&mut dht).map_err(e)?;
    bob.sync(&mut dht).map_err(e)?;
    alice.send_text(&mut dht, "po rotacji").map_err(e)?;
    bob.sync(&mut dht).map_err(e)?;
    r.step(
        "epoch rotation",
        bob.st.epoch == before + 1
            && alice.epoch_authenticator() == bob.epoch_authenticator()
            && bob.st.inbox.iter().any(|m| m.text == "po rotacji"),
        format!("epoch {before} → {}", bob.st.epoch),
    );

    // 6. Restart: state saved and restored.
    let snap = bob.snapshot();
    r.sizes.push(("Persisted member state".into(), snap.len()));
    drop(bob);
    let mut bob = r
        .time("restore state", || Member::restore(&snap))
        .map_err(e)?;
    alice.send_text(&mut dht, "po restarcie").map_err(e)?;
    bob.sync(&mut dht).map_err(e)?;
    r.step(
        "restart restores MLS state",
        bob.st.inbox.iter().any(|m| m.text == "po restarcie")
            && bob.epoch_authenticator() == alice.epoch_authenticator(),
        "decrypts new messages after restore",
    );

    // 7. Removal: Bob cannot read anything afterwards.
    let bob_cik = bob.st.cik.clone();
    let old_control = bob.st.control.clone();
    r.time("commit Remove + move", || -> Result<(), String> {
        alice.stage_remove(&mut dht, &bob_cik).map_err(e)?;
        Ok(())
    })?;
    r.sizes
        .push(("Commit (Remove)".into(), pending_size(&alice).0));
    alice.publish_pending(&mut dht).map_err(e)?;
    bob.sync(&mut dht).map_err(e)?;
    let secret_text = "Bob tego nie przeczyta";
    alice.send_text(&mut dht, secret_text).map_err(e)?;
    // Hand Bob the raw ciphertext from Alice's new outbox anyway.
    let new_outbox = alice.my_outbox().unwrap_or_default();
    let mut leaked = false;
    for k in 1..=4 {
        if let Ok(Some(v)) = dht.get(&new_outbox, k) {
            if let Ok((_, body)) = crate::wire::reassemble(&[v]) {
                if bob.try_decrypt(&body).is_some() {
                    leaked = true;
                }
            }
        }
    }
    bob.sync(&mut dht).map_err(e)?;
    r.step(
        "removed member cannot decrypt later messages",
        bob.st.removed
            && !leaked
            && !bob.st.inbox.iter().any(|m| m.text == secret_text)
            && bob.st.control == old_control
            && alice.st.control != old_control,
        "Bob saw the removal, not the new records or the new message",
    );
    r.dht_writes = dht.writes;
    let fits = r
        .sizes
        .iter()
        .all(|(n, s)| n.starts_with("Persisted") || *s <= MAX_SUBKEY_BYTES);
    r.step(
        "every MLS object fits one 32 KiB subkey (2 members)",
        fits,
        "",
    );
    Ok(())
}
