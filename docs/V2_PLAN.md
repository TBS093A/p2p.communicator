# v2 implementation plan

From the approved protocol (PROTOCOL.md part B) and the proof of concept
(`native/mls_poc`, all F1–F19 passing) to v2 in the app. **For approval
before any code.** Each phase is one or more PRs, merged only when CI
(including DAST) is green; v1 keeps working until phase 5.

## The main decision: how the Rust core and Veilid meet

The PoC's protocol logic (MLS via OpenMLS, control log, generations, moves,
takeover) is Rust and calls a DHT synchronously (`&mut MockDht`). In the app
the DHT is Veilid, driven from Dart through `veilid-flutter`, and every
operation is asynchronous and network-bound.

| Option | How | Verdict |
| --- | --- | --- |
| A. Rust calls back into Dart for each DHT read/write | FFI callbacks that would have to block on async Dart | No: blocking the Dart isolate deadlocks; a second isolate makes every call slow and fragile |
| B. Rust core runs its own veilid-core | Link veilid-core into our crate | No: a second Veilid node in the same app (double traffic, two identities on the network, shared storage clashes) |
| **C. Rust core is "sans-IO"** | Dart reads the records the core asks for into a snapshot, calls the core with it; the core returns the writes to make and the reads it still needs; Dart performs them and repeats | **Proposed.** The PoC logic stays almost as is (the `Dht` trait gets a snapshot implementation), all networking stays in Dart where the v1 sync work (#20: notified values, quick retries, freshness) already lives, and the core is fully testable with the existing mock |

With C, one sync round is:

1. Dart asks the core which records/subkeys it needs (control header and
   log tail, outbox heads and slots, rendezvous slots).
2. Dart fetches them through the existing `Dht` helpers (freshness gate,
   retries) and passes them in as a snapshot.
3. The core applies everything it can (commits in order, messages, moves)
   and returns: writes to perform (each idempotent, already persisted in
   its state, §B5.1 "Publishing"), records to create, more reads needed,
   and events for the UI (new messages, membership changes, warnings).
4. Dart performs writes/creations, feeds results (e.g. new record keys)
   back, and repeats until the core needs nothing more.

Creating records (Veilid assigns the key) is a step like any other: the core
asks for "a new record with owner key K", Dart creates it and returns the
key in the next round.

## Phases

### Phase 1: the core in the app (no user-visible change)

* `native/p2pc_core`: the PoC's `member.rs`/`wire.rs` turned into a library
  with a `Dht` trait (mock for tests, snapshot for the app) and the sans-IO
  API above; the PoC tests keep running against it.
* FFI with a small JSON-in/JSON-out surface (like the PoC's), built for the
  app through a Flutter build hook (like `veilid-flutter`): Android arm64
  (16 KB aligned) and iOS.
* Core state (MLS group state, keys, log position) persisted in the PIN
  vault, encrypted, written before any dependent publish.
* CI: core tests + F1–F19 on every PR touching it; the app builds with it.
* Phone measurements (open item from §B13) on the real app build.

### Phase 2: a v2 group you can actually use (behind a switch)

* "Nowa grupa (v2, eksperymentalne)" next to the existing kinds.
* Create a group (control record, admin's CIK), `p2pc2.` invite with QR,
  **out-of-band check of the admin's fingerprint** before joining (§B4),
  admin approves the join request, Welcome, both sides talk.
* E2EE text messages in MLS `PrivateMessage`s, padded (§B8), `prev` chain.
* Reuses the v1 chat UI (bubbles, replies, typing as an ephemeral E2EE
  message, reactions as E2EE messages) on top of a `V2RoomSession` that
  exposes the same surface as `RoomSession`.
* DAST: two members on one emulator (two app sessions or a second Veilid
  identity), create → invite → verify → join → message both ways.

### Phase 3: membership changes

* Removal with the move to a fresh generation (§B5.3), resumable; offline
  members within the grace period.
* Regular `Update`s for post-compromise security (§B5.1).
* Admin handover, designated successors, takeover after `T_successor`
  (§B5.4), fork warning (F14), diverging history check (F19).
* Proposals carried by value (decided after the PoC).

### Phase 4: media, identities, metadata

* Encrypted media before chunking (§B9).
* One identity per conversation by default; global profile as an opt-in
  link (§B10); DMs as two-member groups.
* Presence opt-in, coarse (§B8).

### Phase 5: v1 read-only and the move

* v1 rooms read-only, marked "old protocol" (§B11).
* "Przenieś do v2": create a v2 group and announce it in the v1 room as a
  hint; joining still requires the fingerprint check.
* v2 becomes the default; the switch from phase 2 goes away.

## Open before v2 ships (not blocking phase 1)

* Crypto provider without RUSTSEC-2026-0387 (§B7, upstream).
* Independent audit of the protocol and the core (THREAT_MODEL, AUDIT plan).
* Control-log write repair by the admin (F16 is "partly").

## What I need decided now

1. Option C (sans-IO core, networking stays in Dart).
2. Phase 2 behind an "eksperymentalne" switch, v1 untouched until phase 5.
