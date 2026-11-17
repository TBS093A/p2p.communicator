# Audit plan (v2)

v2 became the default on 17 Nov 2026 **before** an independent audit
(THREAT_MODEL §10 q6). This plan says what an outside reviewer should look
at, in which order, and what they get, so the audit can start without a
long onboarding. It does not replace the audit.

## Scope

In order of priority:

1. **Protocol design** against the threat model:
   [THREAT_MODEL.md](THREAT_MODEL.md) and [PROTOCOL.md](PROTOCOL.md) part B.
   In particular: the admin-written control log and its ordering rules
   (§B5.2), removal by moving to a fresh record generation (§B5.3),
   handover and takeover (§B5.4), proposals copied into the log (§B5.1),
   DM admission by a signed proof (§B10, F25), join approval (§B4 step 4),
   private conversations in password slots (§B11.1).
2. **The Rust core** (`native/mls_poc/src`, built into the app through
   `packages/p2pc_core`):
   * `member.rs`: the protocol state machine on top of OpenMLS 0.9.2;
   * `api.rs`, `snapshot.rs`, `ffi.rs`: the sans-IO JSON rounds and the
     C ABI the app calls (input validation, no panics across FFI);
   * `wire.rs`: chunking, control header, application messages.
3. **App-side cryptography and storage** (Dart):
   * `lib/core/crypto.dart`: thin layer over Veilid VLD0 (XChaCha20-
     Poly1305, BLAKE3, Argon2, Ed25519, HPKE);
   * `lib/vault/pin_vault.dart`: PIN vault, password slots, decoys,
     lockout, derived areas (§A6, §B11.1);
   * `lib/room/blob_store.dart`: media sealed per file before chunking
     (§B9).
4. **Glue that decides what the user sees** (`lib/v2/`): `v2_groups.dart`
   (admin and member duties, approvals, DMs, presence, moves),
   `v2_room_session.dart`, `private_v2.dart`, `veilid_core_dht.dart`.

Out of scope: Veilid itself (network, routing, record encryption) and
OpenMLS internals, beyond how this code uses them; v1 rooms, which are
read-only now (§B11).

## Questions the audit should answer

* Can a member, a removed member, a storage node or someone holding an
  invite make another member accept a state they should not (a commit, a
  member list, an admin, a generation move)?
* Does any path accept a control-log entry, a Takeover or an
  AdminTransfer from someone other than the current admin?
* Can a removed member find or read the group's new records?
* Is forward secrecy kept in practice (past epoch secrets deleted after
  the retention window, nothing persisted that undoes it)?
* Do the persistence rules hold: state written before any dependent
  publish, publications resumable with identical bytes (F9)?
* Can malformed or hostile input (DHT values, invites, join requests, JSON
  rounds over FFI) crash the app or change state? (F18 covers part.)
* Does the PIN vault leak which private conversations exist (file sizes,
  counts, timing), and is the lockout sound?
* Is media key handling correct (fresh key per file, chunk index and count
  bound, no plaintext in records)?

## What the reviewer gets

* The documents above, with decisions and their dates.
* Tests that pin the intended behaviour:
  * `native/mls_poc/tests/failures.rs`: failure scenarios F1–F25
    (PROTOCOL §B12);
  * `native/mls_poc/tests/{api,approval,snapshot}.rs`: the API as the app
    drives it, approval, the sans-IO host;
  * `test/v2_groups_test.dart` and the rest of `test/`: the app layer on
    an in-memory DHT;
  * `integration_test/`: DAST on an emulator with a real Veilid node
    (screenshots per step in the CI artifact).
* CI: semgrep, CodeQL, gitleaks, osv-scanner, clippy (`-D warnings`).

## Known and accepted before the audit

* RUSTSEC-2026-0387 in the crypto provider's NIST-curve code, which
  ciphersuite 0x0003 never runs (§B7; exception until 2027-02-09).
* Write timing and record access patterns are visible to storage nodes
  (THREAT_MODEL A10, §7).
* The admin is a single point for membership changes; recovery is by
  designated successors after 14 days (§B5.4).
* The PoC's join request is not HPKE-sealed to the admin (the KeyPackage
  is public data; sealing would hide metadata only).

## Outcome

A written report with findings rated by severity, each fixed or
explicitly accepted (with a reason) in PROTOCOL.md / THREAT_MODEL.md
before THREAT_MODEL §10 q6 is closed.
