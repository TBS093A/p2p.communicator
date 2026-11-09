# v2 proof of concept: OpenMLS over a mocked DHT

Implements docs/PROTOCOL.md §B13. Nothing in the app (`lib/`) uses it yet.

* **OpenMLS 0.9.2**, ciphersuite **0x0003**
  (`MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519`), enforced on join.
* **Mock DHT** (`src/dht.rs`): records, subkeys, owner and per-subkey
  writers, the 32 KiB value limit, propagation delay, lost writes, stale
  (rolled back) values, and injected garbage.
* **Protocol** (`src/member.rs`):
  * one identity (CIK) per conversation;
  * the admin-written control record, with a hash-chained log;
  * one outbox per member;
  * join through a one-time rendezvous;
  * a removal moves the group to a new generation, as a persisted state
    machine;
  * successor takeover;
  * state saved and restored.
* **FFI** (`src/ffi.rs`): a C ABI called from Flutter
  (`flutter_test/mls_poc_ffi_test.dart`).

```sh
cargo test --manifest-path native/mls_poc/Cargo.toml          # scenario + F1–F18
cargo build --manifest-path native/mls_poc/Cargo.toml && \
  flutter test native/mls_poc/flutter_test                    # through FFI
```

CI: `.github/workflows/mls-poc.yml`. It runs fmt, clippy `-D warnings`,
the tests, the measurements (in the job summary) and the FFI test. SCA scans
`Cargo.lock` as a gating check.

## Minimal scenario (§B13)

| Step | Result |
| --- | --- |
| Two independent identities | ✅ |
| Create a group | ✅ |
| Second member joins via KeyPackage / Welcome | ✅ same epoch authenticator |
| Encrypted messages both ways | ✅ |
| Epoch rotation (Update proposal, admin commit) | ✅ |
| Restart: MLS state saved and restored | ✅ decrypts new messages |
| Removal; the removed member cannot decrypt later messages | ✅ even with the raw ciphertext in hand, and it never learns the new records |
| Same scenario from Flutter through FFI | ✅ |

## Failure scenarios (§B12)

| # | Test (`tests/failures.rs`) | Result |
| --- | --- | --- |
| F1 | `f01_dht_delay` | ✅ messages and commits not yet visible are waited for. A message from the next epoch that arrives before its commit is retried, not dropped. |
| F2 | `f02_admin_offline` | ✅ messages flow, the proposal queues, the epoch is frozen until the admin commits |
| F3 | `f03_duplicated_commit` | ✅ second copy ignored |
| F4 | `f04_replayed_old_commit` | ✅ rejected by the epoch rule |
| F5 | `f05_rollback` | ✅ stale control record ignored; progress resumes |
| F6 | `f06_out_of_order` | ✅ out-of-order messages decrypt. A gap shows only while a message is really missing. More than 100 skipped keys gives "could not decrypt". |
| F7 | `f07_previous_epoch` | ✅ readable in the retention window; after the past epoch secrets are deleted it can't be decrypted. |
| F8 | `f08_restart_during_move`, `f08b_second_removal_during_move` | ✅ restart after every step with no second outbox. A second removal mid-move follows the chain of Move pointers. |
| F9 | `f09_admin_restart_mid_commit` | ✅ the same commit is republished, never a different one for the same epoch |
| F10 | `f10_offline_during_removal`, `f10_offline_beyond_grace` | ✅ catches up within the grace period; afterwards left behind |
| F11 | `f11_member_device_lost` | ✅ (partly, as planned) rejoins as a new identity; the admin removes the old leaf |
| F12 | `f12_admin_device_lost`, `f12_early_takeover_rejected` | ✅ the successor takes over after `T_successor`; an early takeover is rejected |
| F13 | `f13_concurrent_proposals` | ✅ two proposals, one commit, the same epoch for everyone |
| F14 | `f14_fork_after_takeover` | ✅ moved members ignore the old admin; the forked member detects it and is re-added as a new identity |
| F15 | `f15_removed_member_keeps_writing` | ✅ cannot even encrypt; the old outbox is no longer read |
| F16 | `f16_lost_writes` | ✅ (partly) a lost outbox write shows as a gap and is re-sent by the writer. Lost control-log writes are only waited for, not repaired. |
| F17 | `f17_oversized_welcome` | ✅ Welcome and commit split across subkeys and joined |
| F18 | `f18_fuzz_parsers`, `f18_garbage_in_records`, `f18_garbage_join_request` | ✅ 20 000 random inputs to every parser, garbage in every record, garbage join requests: no crash and no state change |

## Measurements

Sizes (bytes):

| Object | 2 members | 151 members |
| --- | --- | --- |
| KeyPackage | 337 | — |
| Welcome | 909 | **59 207** (2 subkeys) |
| Commit (Add) | 830 | **51 776** (2 subkeys) |
| Commit (Update) | 830 | |
| Commit (Remove) | 574 | |
| Application message (short text, padded to 256) | 318 | |
| Persisted member state | ~129 000 | (JSON; binary would be about a third) |

A Welcome costs about 390 B per member, so one 32 KiB subkey holds a
Welcome for about 80 members. A bulk Add commit grows the same way.
Chunking is therefore needed in practice, not just in theory.

Time per operation, release build, x86-64 desktop:

| Operation | ms |
| --- | --- |
| identity | 0.11 |
| create group | 0.43 |
| KeyPackage | 0.26 |
| commit Add | 1.31 |
| process Welcome | 0.66 |
| encrypt message | 0.12 |
| sync + decrypt | 0.11 |
| commit Update | 0.92 |
| restore state | 2.56 |
| commit Remove + move | 0.58 |

**Still open: timings on a phone.** These numbers are desktop timings.
§B13 asks for times on a phone. That needs an Android build of the crate
(cargo-ndk) and a run on a device, which hasn't been done yet.

## What the PoC showed (proposed changes to PROTOCOL.md)

1. **The control header should chain the log, not the previous header.**
   §B3 has `prevHeaderHash`. Members often skip intermediate headers (they
   read only the newest one), so a header-to-header chain can't be checked.
   The PoC uses `logHash`, a hash chain over every log value. A member
   recomputes it over the entries it reads and so detects withheld, swapped
   or rolled-back entries (F5, F18).
2. **Everything published after a commit is encrypted once and persisted
   before it is written** (F9). Without this, an admin restarting
   mid-publication re-encrypts the Directory or Move message into different
   bytes at an already published position. That breaks the log chain for
   every member who already read it. Publishing becomes three idempotent
   phases: write the commit, merge and encrypt what follows it, write that
   and the header.
3. **After a takeover the new admin should remove the lost admin's leaf in
   the same step.** Otherwise every member waits for the old admin's
   announcement until the grace period ends (seen in F14).
4. **Proposals by reference need the proposal before the commit.** A
   commit that references a proposal the member hasn't read yet is not
   applicable until it arrives (handled: "commit not applicable yet",
   retried). A proposal lost for good would block that member. For v2.0,
   the admin should commit only proposals older than one sync round, or
   carry them by value. To be decided.
5. **Fork detection** works as: "the first successor committed, in its
   outbox, an epoch I already left through the admin's commit". The forked
   member must rejoin as a new identity, because MLS forbids the same
   signature key twice. This is consistent with F11.
6. **Ciphersuite and provider.** `openmls_rust_crypto` always links the
   NIST curves. Through them it pulls in `crypto-bigint 0.5.5` with
   RUSTSEC-2026-0387 (timing). 0x0003 never runs that code, and the PoC
   rejects groups with another ciphersuite. CI has a 3-month exception with
   a justification (`osv-scanner.toml`). Before v2 ships: a provider without
   the NIST curves (libcrux) or an OpenMLS release on `elliptic-curve 0.14`.
   `Cargo.lock` also lists `libcrux-kem 0.0.9`.
   * It has RUSTSEC-2026-0330 and RUSTSEC-2026-0331 (CVSS 8.7, a panic on
     decoding too-short ML-KEM keys).
   * It is only an optional dependency of `hpke-rs` (the `libcrux` feature),
     which nothing enables, so it is not compiled.
   * CI fails if it ever becomes part of the build.
   * The fix (`hpke-rs 0.8`) needs an `openmls_rust_crypto` release that
     accepts it.
7. **Retention works as specified:** keep 1 past epoch, and delete it
   explicitly after 24 h (`delete_past_epoch_secrets`). 100 skipped keys
   per sender is confirmed as the limit.

## PoC simplifications (not decisions)

* The join request is not HPKE-sealed to the admin's CIK.
* The KeyPackage is public data; sealing it only hides metadata.
* Outboxes don't wrap around (no 200-message ring).
* Message padding is OpenMLS `padding_size(256)`, not the 256/1024/4096
  buckets.
* A logical clock: 1 tick = 1 hour for `T_successor` (14 days) and the
  grace period (30 days).
* No real Veilid. The mock enforces the record and subkey rules, not
  networking.
