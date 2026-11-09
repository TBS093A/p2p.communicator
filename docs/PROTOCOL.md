# Protocol

Status: part A describes v1 on `main`; part B is the **approved v2
direction** (9 Nov 2026), not implemented yet.

* **Part A** documents protocol v1 as implemented on `main`. It is
  descriptive: if code and this text disagree, the code wins and this text
  is a bug.
* **Part B** specifies protocol v2, following the decisions in
  [THREAT_MODEL.md §9](THREAT_MODEL.md#9-decisions-taken-9-nov-2026). Nothing
  in part B is implemented. The first step is a proof of concept (§B13);
  **no large code migration before the PoC is approved**. v2 groups cannot
  be read by v1 apps, and v1 rooms are not upgraded in place (§B11).

---

# Part A: protocol v1 (as implemented)

## A1. Primitives

All crypto comes from Veilid's VLD0 crypto system (`lib/core/crypto.dart`):

| Use | Primitive |
| --- | --- |
| Identity / record owner keys | Ed25519 key pairs |
| Sealing to a public key (DM invites, migration) | HPKE, Ed25519 → X25519 bridge, with an authenticated context string |
| Symmetric encryption (local vault, migration entries) | XChaCha20-Poly1305; a context string selects a derived key (`subsecret(key, "aead:" + context)`) |
| Hash, key derivation | BLAKE3 (`subkey(key, label)` = BLAKE3(label ‖ 0x00 ‖ key)) |
| Password / PIN stretching | Argon2 (Veilid defaults) |
| Signatures (DM invites) | Ed25519 |
| DHT record encryption | Veilid's own, keyed by the secret embedded in each record key |

## A2. Identities

| Identity | Key | Lives in | Visible to |
| --- | --- | --- | --- |
| App identity | One Ed25519 key pair per installation, created at setup | App vault slot (`identity`) | Everyone who can read your global profile (`id` field) |
| Global profile | DHT record (DFLT, 1 subkey) **owned by the app identity key** | Record key in the app slot (`profileKey`) | Every member of every DM/group you are in (via `p`) |
| Outbox owner | Fresh random Ed25519 key pair **per outbox**, i.e. per room | `RoomSecrets.outboxWriter` | Nobody (only the record key is shared) |
| Roster owner | Fresh random key pair per room, **shared with every member** | `RoomSecrets.rosterWriter`, inside every invite | Every member and everyone who ever saw the invite |

Room kinds (`RoomKind`): `dm` and `group` are *public* (listed, linked to
the global profile through `p`); `private` rooms open with their own
password and never reference the global profile.

## A3. DHT records

Record limits: 32 KiB per subkey, 1 MiB per record. A record key has the form
`<kind>:<key>:<encryptionSecret>`; holding it is enough to read the record.

### Roster (one per room)

Schema `DFLT(oCnt = 64)`, owner = shared roster writer.

| Subkey | Content (JSON) |
| --- | --- |
| 0 | Room meta: `{"v": 1, "name", "kind": "dm" \| "group" \| "private"}` plus the shared room style (`avatar`, `bg`, `bgImg`, `dim`, `bubble`, `otherBubble`, `bars`, `accent`, `emoji`) |
| 1..63 | `{"o": outboxRecordKey, "n": displayName, "p"?: globalProfileKey}`, one per member |

A joiner claims the first empty slot: read → write → read back, and if
another value won, try the next slot (`RoomProtocol._claimSlot`). Max 63
members.

### Outbox (one per member per room)

Schema `DFLT(oCnt = 1 + 200)`, owner = that member's random outbox key.

| Subkey | Content |
| --- | --- |
| 0 (head) | Public rooms: `{"name", "p": globalProfileKey, "count"}`. Private rooms: the full per-room profile (name, color, avatar ref) plus `"count"`. |
| 1..200 | Message number `i` lives at subkey `1 + i % 200` (ring). Max 4000 bytes. |

Sending (`RoomSession._append`): write the message to its slot, then write
the head with `count = seq + 1`. Readers watch every outbox (and poll every
20 s as a fallback).

Receiving (`RoomSession._syncMember`, `OutboxCursor`): for each outbox keep
`next` (first seq never asked for) and a set of `missing` seqs. Each sync
fetches the missing ones, then `next..count-1`, skipping seqs below
`count - 200` (overwritten). A slot that is empty or still holds an older
seq stays missing and is retried; a slot holding a newer seq is given up.

### Global profile (one per user)

Schema `DFLT(oCnt = 1)`, owner = app identity key. Subkey 0:
`{"v": 1, "name", "id": identityPublicKey, "avatar"?, "color"?, "status", "seen"}`.
`seen` is refreshed every 60 s unless the status is `invisible`. Others
show you as offline after 3 min without a heartbeat.

### Blobs (media)

`BlobStore`: the file is split into 32 000-byte chunks, 30 chunks per
record, each record `DFLT(oCnt = chunks)` with a fresh random owner. The
message carries a `MediaRef`: `{mime, size, hash (BLAKE3 of the plain
file), rec: [recordKeys], cs, cpr, w?, h?, d?}`. The receiver checks the
hash after download. The bytes in the chunks are **not encrypted by the
app**; confidentiality rests on the record keys staying inside the room.

## A4. Messages

Wire form in an outbox subkey (`ChatMessage.toWire`):

```json
{"id": "<uuid v4>", "seq": 17, "ts": 1731150000000, "t": "text",
 "text": "...", "m": { MediaRef }, "x": { type-specific }}
```

Types: `text`, `image`, `video`, `voice`, and the hidden `dmInvite`. An
unknown `t` is skipped (newer app version). The author is implied by the
outbox the message was read from, not by a field.

## A5. Invites

### Room invite (QR / text)

`"p2pc1." + base64url(JSON{"n": roomName, "r": rosterKey, "w": rosterWriterKeyPair, "k": kind})`,
padding stripped. **The invite is membership:** it contains the roster's
read key and its write key pair. There is no expiry, no single use and no
way to revoke it.

### DM invite (inside a shared group)

To start a DM with a member of a shared group:

1. Create a new `dm` room.
2. `payload = {"invite": roomInvite, "from": myProfileKey, "sig": Ed25519(identity, S)}`,
   where `S = JSON["p2pc-dm-invite-sig-v1", invite, from, recipientIdentity]`.
3. `sealed = HPKE-seal(recipientIdentity, payload, context "p2pc-dm-invite-v1")`.
4. Post a hidden `dmInvite` message `{"x": {"s": base64url(sealed)}}` in the
   shared group.

Every member tries to open it; only the recipient can. The recipient loads
the global profile at `from`, verifies `sig` against its `id`, and only then
shows the invite. Unsigned or forged invites are dropped (since #13).

## A6. Local storage (PIN vault)

`lib/vault/pin_vault.dart`:

* `master = Argon2(domain ‖ secret ‖ devicePepper, vaultSalt)`. The 32-byte
  pepper is kept in Android Keystore-backed storage.
* The app PIN (domain `app`) opens the app slot: identity, profile key,
  public room list. Each private-room password (empty domain) opens exactly
  one private room slot.
* The slot file name is derived from `master`; every slot is padded to
  4096 bytes, and decoy slots are written next to real ones.
* After 5 wrong attempts (app PIN and passwords count together), each
  further wrong attempt locks the vault for 30 s, doubling up to 1 h.
* Room caches and media are AEAD-sealed under keys derived from the slot
  key. Decrypted media lives in `<temp>/plain` while the app is unlocked and
  is wiped on lock and on the next start (since #13).

## A7. Moving to a new phone

`lib/migration/`: the new phone shows a one-time public key as a QR. The
old phone writes
`"P2PCMOVE1" ‖ len ‖ HPKE-seal(receiver, dataKey) ‖ (len ‖ AEAD(dataKey, nameLen ‖ name ‖ data))*`
with an end marker. The identity, profile key, public rooms with history,
cached media and the private rooms unlocked for the move are transferred.
The new phone re-encrypts everything under its own PIN and pepper. The old
phone may then wipe itself. Both phones hold the same writer keys until it
does.

## A8. Versioning

* Invites: prefix `p2pc1.`
* Roster meta and profile: `"v": 1`
* Vault payloads: `"v": 1`
* Context strings: `p2pc-dm-invite-v1`, `p2pc-dm-invite-sig-v1`
* Unknown message types are ignored; there is no protocol negotiation.

## A9. What v1 guarantees, in one paragraph

Network nodes that do not hold a record key see only ciphertext. Within a
room, everyone who has ever held the invite is a full and permanent member
who can read every outbox and rewrite the roster. Messages are attributable
to an outbox (its owner key), but the outbox-to-person mapping is in the
writable roster. There is no forward secrecy and no removal. DMs and groups
are linkable through the global profile; private rooms are not.

---

# Part B: protocol v2 (approved direction)

## B0. Scope: v2.0 and later

| In v2.0 | Later (not v2.0) |
| --- | --- |
| App-level E2EE with MLS (RFC 9420) via OpenMLS | Several admins with **individual** keys (no shared admin key) |
| One identity key per conversation, by default | Multi-device with separate device keys |
| One admin as commit sequencer, plus admin handover and successor recovery | Cover traffic, batching or jitter of writes |
| Join requests approved by the admin; no capability invites | Direct P2P transfer for large media |
| Removal = new MLS epoch **and** a fresh record generation, resumable | Periodic record generation rotation without removals |
| Out-of-band key verification; warning on any key change | Post-quantum ciphersuite |
| Presence off by default, per-conversation opt-in, coarse, E2EE | Independent security audit |
| Global profile off by default, per-conversation opt-in link | |
| Media encrypted before chunking; padded messages | |
| v1 rooms read-only, move to new v2 groups with verified admin | |
| Defined behaviour for every failure in §B12 | |

## B1. Principles

1. **Two layers.** Everything the app puts in the DHT is encrypted and
   authenticated by the app (E2EE) first. Veilid record encryption stays as
   an outer layer. A leaked record key then reveals only ciphertext and
   sizes.
2. **No capability is shared by everyone.** Each writer has their own key.
   Membership changes are signed by the admin and strictly ordered.
3. **Membership is a sequence of epochs.** Every change starts a new MLS
   epoch. A removed member never gets the new epoch's keys **and** the group
   moves to records the removed member cannot find (§B5.3).
4. **No home-grown crypto.** Group key agreement and the message ratchet
   come from MLS and an audited implementation (OpenMLS). No custom ratchet,
   no custom key agreement.
5. **One identity per conversation by default.** Linking a conversation to
   your global profile is an explicit, per-conversation choice.
6. **Minimal metadata.** No names or profile pointers in clear, no global
   heartbeat, padded message sizes.
7. **Privacy over convenience**, as long as the app stays usable.

## B2. Keys

| Key | Scope | Purpose |
| --- | --- | --- |
| Conversation identity key `CIK` (Ed25519) | One per conversation per user | MLS credential and signature key: your identity inside that conversation. Random, so conversations are unlinkable. |
| Record owner keys | Fresh random per record per generation | Write the control record (admin) or a member's outbox. Never reused across generations. |
| MLS epoch secrets | Per group, per epoch | Encrypt application messages. Old epochs' secrets are deleted after the retention window (§B12) for forward secrecy. |
| Media key | Per file | AEAD key for a blob; travels only inside an E2EE message. |
| Global identity `GIK` (optional) | Per user | Only if the user links a conversation to a global profile (§B10). |
| Device key `DK` | Per device | Later (multi-device). Not in v2.0. |

## B3. Records and generations

A group's DHT records belong to a **generation** `g`. Joins do not change
the generation; every removal (and every admin change) starts a new one.

| Record | Schema / owner | Content |
| --- | --- | --- |
| **Control record** `C_g` | `DFLT`, owner = admin's random key for generation `g` | Subkey 0: header `{v: 2, gen, epoch, logCount, logHash}`. Subkeys 1..N: the log, in order: MLS commits and the admin's MLS messages that belong to them (`Directory`, `Move`). Only the admin writes it. |
| **Member outbox** `O_g,i` | `DFLT`, owner = member's random key for generation `g` | Subkey 0: head `{count}` only, padded. Subkeys 1..ring: MLS `PrivateMessage`s. |
| **Join rendezvous** | `SMPL`: owner = admin, 1 member subkey whose key pair is in the invite | The joiner writes one MLS `KeyPackage`, sealed to the admin's `CIK`. One-time. |
| **Blob** | `DFLT`, random owner | Chunks of the **AEAD-encrypted** file. |
| **Global profile** (optional) | `DFLT`, owner `GIK` | Name and avatar only; no `seen` (§B8). |

There is no separate roster: **the MLS group state is the member list**,
and every member derives it from the commit log. Which outbox belongs to
which member, and the successor list (§B5.4), travel in a `Directory`
message: an MLS application message the admin appends to the log after
each commit that changes them, so members get it in order and E2EE.

**`logHash`** chains the whole log, not the headers:
`logHash_0 = ""`, `logHash_n = SHA-256(logHash_{n-1} || value_n)` over
the raw value of every log subkey `n`, restarting at each generation.
Members often skip intermediate headers and read only the newest one, so a
header-to-header chain (`prevHeaderHash`, the earlier draft) cannot be
checked. A member recomputes `logHash` over the entries it reads, which
detects a withheld, swapped or rolled-back entry (§B5.2).

SMPL schemas fix their member list at creation, so they suit one-time
rendezvous records.

**Chunking is required, not optional.** A Welcome costs about 390 bytes
per member, so one 32 KiB subkey holds a Welcome for about 80 members; a
commit that adds many members grows the same way (PoC: Welcome 59 207 B
and Add commit 51 776 B for 151 members). Any MLS message larger than one
subkey is split across consecutive subkeys, each with a chunk header
(`kind`, index, total), and reassembled by the reader. A reader that does
not have every chunk yet waits, exactly as for an unpropagated value.

## B4. Joining

1. The admin creates an invite:
   `"p2pc2." + base64url({rendezvousKey, rendezvousWriter, adminCIK, groupHint?, expiresAt})`.
   It carries **no** read access to the group and no write access except
   one subkey in the rendezvous record.
2. **Out-of-band verification.** The joiner verifies `adminCIK` through an
   independent channel: scanning the admin's QR in person, or comparing the
   admin's fingerprint (§B6) over a channel they already trust. Without
   that check, the app does not send a join request (THREAT_MODEL §10 q2).
3. The joiner generates a fresh `CIK`, creates an MLS `KeyPackage`, seals it
   to `adminCIK` and writes it to the rendezvous slot.
4. The admin's app shows the request (the joiner's chosen name and `CIK`
   fingerprint). The admin approves it, ideally after checking the joiner's
   fingerprint the same way.
5. The admin publishes an MLS `Add` commit to `C_g` (§B5.1, "Publishing")
   and a `Welcome` sealed to the joiner's KeyPackage, written to the
   rendezvous record. The Welcome carries the key of `C_g`; the members'
   outbox keys come from the next `Directory` in the log.
6. The joiner creates `O_g,joiner` and announces its key in an MLS message;
   the admin includes it in the next `Directory`.

A leaked invite lets someone *request* to join, nothing more. Expired or
used invites are ignored.

## B5. Membership changes, ordering and epochs

### B5.1 Proposals and commits

* Any member may **propose** Add/Remove/Update as an MLS proposal sent in
  their outbox.
* Only the admin **commits**: it writes commits to `C_g` in order. The
  admin is the sequencer, which gives MLS the total order it needs.
* Every member sends an `Update` (fresh leaf key) at least every 7 days or
  500 messages, whichever comes first, for post-compromise security. The
  admin commits pending Updates.
* While the admin is offline, proposals queue and membership does not
  change; **application messages keep flowing** in the current epoch.

**Proposals go into the commit by value** (decided 9 Nov 2026). A member's
proposal in its outbox is only a request to the admin; the admin's commit
carries the proposal itself, not a reference to it. Members never need the
original proposal to apply a commit, so a proposal a member never read
(lost or not yet propagated) cannot block it. Commits get larger, which
chunking (§B3) already handles. The PoC used proposals by reference (the
OpenMLS default), where a lost proposal would block every member that
never read it; the implementation switches to by value.

**Publishing a commit.** Anything the admin publishes after a commit (the
`Directory`, a `Move`) is an MLS message whose ciphertext changes every
time it is encrypted. If the admin restarted mid-publication and encrypted
it again, a position members have already read would get different bytes
and break `logHash` for all of them (F9). Publishing is therefore three
idempotent phases, each persisted before the next starts:

1. **Prepare:** create the commit, merge it locally, encrypt every message
   that follows it, and persist the commit, those ciphertexts and the log
   positions they go to (`pending`).
2. **Write the log:** write the persisted bytes to their positions. Re-running
   it writes the same bytes.
3. **Write the header:** write `{gen, epoch, logCount, logHash}` and clear
   `pending`.

After a restart the admin resumes from `pending`; it never creates a second
commit for the same epoch or re-encrypts a message.

### B5.2 Ordering, replay and rollback rules

Every member persists `(gen, epoch, logCount, logHash)` of the last state
it accepted, and applies these rules:

1. A commit is accepted only if it is signed by the current admin's `CIK`,
   is for exactly `epoch + 1`, and is the next entry in `C_g`'s log.
2. A commit with a lower or equal epoch is a duplicate or a replay: ignored
   (logged if its content differs from the one accepted for that epoch).
3. A control record value whose `gen`, `epoch` or `logCount` is lower than
   the persisted one is a rollback by a storage node: ignored, and the
   member keeps polling.
4. The member reads every new log entry from `logCount + 1` to the header's
   `logCount` and recomputes `logHash` from its persisted one. If an entry is
   missing, it waits. If the result differs from the header's `logHash`,
   or a header with an unchanged `logCount` carries a different `logHash`,
   the header is rejected.
5. Application messages are accepted only from current members, for the
   current epoch or one still inside the retention window (§B12).
6. A member that sees a peer report (in `ctl`, §B8) the same `gen` and
   `logCount` with a different `logHash` stops accepting new commits and
   shows "group history differs". The group is then treated as a fork (F14,
   F19).

**Who vouches for `logHash`.** The header and every log subkey are DHT
values signed by the owner key of `C_g`, and Veilid rejects writes signed
by anyone else. Members learn `C_g` only inside E2EE messages (Welcome,
`Move`). A storage node can therefore withhold values or serve stale ones
(rules 3–4) but cannot forge them. `logHash` has no signature of its own:
it is authentic because the header is signed by the owner key, and every
commit inside the log carries the admin's MLS signature (rule 1).

**Diverging histories.** What the owner signature does not stop is the
admin itself (or whoever holds its owner key) rewriting a log position
after some members read it, so that members end up with different logs.
Different commits for the same epoch would eventually stop members from
decrypting each other's messages, but that failure gives no explanation.
Rule 6 detects it explicitly: every application message carries the
sender's accepted `{gen, logCount, logHash}`, and members compare them.
### B5.3 Removal and the move to a fresh generation

A removal always moves the group to generation `g + 1`, so the removed
member cannot even watch the group's records afterwards.

Admin:

1. Create `C_{g+1}` with a fresh random owner key and record secret. Write
   its header (`gen = g + 1`).
2. Prepare the MLS `Remove` commit (epoch `e → e + 1`) and the
   `Move{gen: g + 1, control: C_{g+1}}` message encrypted in epoch `e + 1`,
   and persist both as bytes **before** writing anything (§B5.1,
   "Publishing").
3. Append to `C_g`: the commit, then the `Move`. The removed member can
   decrypt the commit (and learns they were removed) but not the `Move`.
4. Mirror the commit into `C_{g+1}`'s log (its `logHash` starts again from
   `""`), so the new generation is self-contained.

Each remaining member (a persisted state machine, every step idempotent):

| State | Action | Next |
| --- | --- | --- |
| `stable(g)` | Sees the commit and `Move` in `C_g`; processes the commit | `moving(g → g+1)` |
| `moving` | Creates `O_{g+1,i}` with a fresh owner key; **persists** its key | `created` |
| `created` | Writes `MyOutbox{gen: g+1, key}` (epoch `e + 1`) as the **last** message in its old outbox `O_g,i` | `announced` |
| `announced` | Reads the other members' announcements from their old outboxes; watches only `C_{g+1}` and the new outboxes; sends only to the new outbox | `stable(g+1)` once all members announced or the grace period ends |

* **Restart at any step** resumes from the persisted state. Re-running a
  step writes the same data (same keys, same message), so it is harmless.
* **Members offline during the move** find the commit and `Move` in `C_g`
  when they come back. The admin keeps `C_g` alive for a **grace period of
  30 days**. A member offline longer than that has to be re-invited.
* **What the removed member still sees:** the commit, then one last
  ciphertext write per member in the old outboxes, then silence. They never
  learn the new record keys.
* Messages a member sent in `O_g,i` in epoch `e` before noticing the
  commit are still decryptable by others inside the retention window.
* A second removal during a move starts `g + 2` from `g + 1`; members
  follow the chain of `Move` pointers.

### B5.4 Admin handover and recovery

* **Handover:** the admin commits an `AdminTransfer{to: CIK}` group context
  extension. The new admin starts generation `g + 1` exactly like §B5.3
  (without a removal), because the old admin holds the owner key of `C_g`.
* **Designated successors:** the admin keeps an ordered successor list in
  the group context (changed only by commits). Members see it.
* **Recovery after admin device loss:** if a member has seen no commit and
  no message from the admin for `T_successor` (default 14 days, set per
  group), the first successor in the list may publish a `Takeover` commit
  in its own outbox and start generation `g + 1`. A member accepts the
  takeover only if it has itself seen no admin activity for
  `T_successor`, and only if `C_g` has no commit for `epoch + 1` yet.
* **The takeover commit also removes the lost admin's leaf.** Otherwise the
  old admin counts as a member who has not announced its new outbox yet,
  and every member keeps waiting for it until the grace period ends (seen in
  the PoC, F14). If the old admin's device comes back, it rejoins as a new
  member.
* **Admin returns after a takeover:** members who moved ignore `C_g`.
  A member that accepted a commit from the old admin first is on a fork. It
  detects this when the takeover commit in the successor's outbox is for an
  epoch it has already left through the old admin's commit. It must rejoin
  as a **new identity** (MLS forbids the same signature key twice in a
  group), consistent with F11. Validated in the PoC (F14).
* **No successor configured:** messaging continues, but membership is
  frozen; the members have to create a new group.

## B6. Identity verification and key changes

* Every member has a **fingerprint** per conversation: a short code
  derived from their `CIK`, shown as text and QR.
* A member is **verified** once you compared their fingerprint out of band.
  The UI shows verified and unverified members differently.
* Every membership change appears in the conversation as a signed event
  ("admin added X", "admin removed Y").
* **A new or changed key for an existing name is never silent:** it is shown
  to everyone as a new, unverified identity. The admin therefore cannot swap
  a member's key without the other members seeing it (THREAT_MODEL S17).

## B7. MLS: requirements and choice

Requirements (approved):

1. A separate cryptographic identity for each conversation.
2. App-level E2EE independent of Veilid DHT encryption.
3. Forward secrecy and post-compromise security, given regular key updates.
4. Epoch rotation on every membership change.
5. Authentication of participants and verification of their keys.
6. Safe handling of delayed, duplicated and out-of-order messages.

Choice: **MLS (RFC 9420) via OpenMLS**, ciphersuite
`MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519` (0x0003, the same
curve family as Veilid), integrated through FFI as `veilid-flutter` does.

| | MLS | Signal Sender Keys | Custom |
| --- | --- | --- | --- |
| Forward secrecy | Yes | Per sender chain | — |
| Post-compromise security | Yes (Update/Commit) | Weak | — |
| Removal cost | O(log n) | O(n) pairwise | — |
| Standard, audited implementation | RFC 9420, OpenMLS | libsignal | No |
| Needs ordered commits | Yes: the admin-written control record (§B5) | No | — |

The app rejects a group or Welcome with any other ciphersuite.

**Crypto provider (to fix before v2 ships).** `openmls_rust_crypto` always
links the NIST curves, which pull in `crypto-bigint 0.5.5` with
RUSTSEC-2026-0387 (a timing issue). 0x0003 never runs that code, and CI has
a 3-month exception with a justification (`native/mls_poc/osv-scanner.toml`).
Before v2 ships, one of:

* a provider without the NIST curves (libcrux), or
* an OpenMLS release on `elliptic-curve 0.14`.

`Cargo.lock` also lists `libcrux-kem 0.0.9` (RUSTSEC-2026-0330 and -0331).
It is only an optional dependency of `hpke-rs` that nothing enables, so it
is not compiled; CI fails if it ever enters the build. The fix (`hpke-rs
0.8`) needs an `openmls_rust_crypto` release that accepts it.

MLS group state (OpenMLS storage) is persisted in the PIN vault, encrypted
under the conversation's vault key, and written **before** any message that
depends on it is published. Retention as tested in the PoC: one past epoch
is kept and its secrets are deleted explicitly after 24 h; at most 100
skipped message keys per sender.

## B8. Application messages, presence and metadata

Inside an MLS `PrivateMessage` (so the author is proven by MLS, not by which
outbox it came from):

```json
{"v": 2, "id": "<random 128-bit>", "seq": 17, "ts": 1731150000000,
 "t": "text", "text": "...",
 "m": {"mime", "size", "hash", "rec": [...], "key": "<media key>", ...},
 "prev": "<hash of my previous message>",
 "ctl": {"gen": 3, "logCount": 41, "logHash": "<hex>"}}
```

* `ctl` is the control-log state the sender has accepted (§B5.2 rule 6).
  It is inside the E2EE payload, so only members see it.

* `prev` chains each sender's messages, so a withheld or swapped message is
  detected (THREAT_MODEL S9).
* The plaintext is padded to the next of 256 / 1024 / 4096 bytes.
* Profile changes (name, avatar, color) are `profile` messages, never fields
  in a head.
* **Presence** is off by default. If enabled for one conversation, the app
  sends a coarse `presence` message there (`active` / `away`), at most once
  every 15 minutes, E2EE like any other message. No global heartbeat, no
  global `seen`, nothing shared across conversations. Turning it off stops
  further updates. The DHT writes themselves still show members when you
  send something; that is accepted and out of scope (THREAT_MODEL §7).

| Leak in v1 | v2.0 |
| --- | --- |
| Names and profile pointers in roster and heads | Only inside E2EE messages |
| `seen` heartbeat every 60 s | None; opt-in coarse presence per conversation |
| Exact message sizes | Padded buckets |
| Same global profile in every DM/group | Per-conversation `CIK`; global link opt-in |
| Removed member keeps watching the room | Fresh record generation on removal |
| Write timing per message | Unchanged (later: batching/jitter) |

## B9. Media

The file is encrypted with a fresh random key (XChaCha20-Poly1305,
chunk-wise, chunk index bound into each chunk's nonce/context) before it is
split into blob records. The key and the plaintext hash travel only inside
the E2EE message. A leaked blob record key reveals only the size.

## B10. Global profile and DMs

* The global profile is **off by default**. A user may link one conversation
  to it by sending a `link` message: `{profileKey, sig}` where `sig` is the
  `GIK` signature over `(groupId, CIK)`. Without it nothing connects that
  conversation to anything else.
* The global profile no longer carries `seen` or a status.
* **DMs** are two-member groups using this protocol. A DM started from a
  group uses a DM invite (as in A5) sealed to the peer's `CIK` **in that
  group** and signed with my `CIK` there, so it reveals no global identity.

## B11. Migration from v1

v1 secrets are in the hands of everyone who ever held an invite, so v1 rooms
are not upgraded in place.

1. A v2 app opens v1 rooms **read-only**: local history stays, nothing is
   written, and the UI marks them as "old protocol".
2. Any member can create a v2 group (becoming its admin) with fresh
   identities and keys.
3. The v2 invite may be **announced** in the v1 room, but that announcement
   is only a hint: a v1 room proves nothing about who wrote it. Joining
   requires the out-of-band check of the admin's `CIK` (§B4 step 2) and the
   admin's approval.
4. No v1 key, roster entry or past membership counts as a credential in v2.
5. v1 invites (`p2pc1.`) can still be scanned, and open read-only.

Private rooms follow the same path; their password slot then points to the
v2 group.

## B12. Failure scenarios

Each row is expected behaviour, tested by the PoC on a mocked DHT (column
"PoC"; tests in `native/mls_poc/tests/failures.rs`, all passing). F19 was
added after the PoC and is tested in the implementation.

| # | Scenario | Expected behaviour | PoC |
| --- | --- | --- | --- |
| F1 | **DHT delay**: a value is not propagated yet | Outbox cursors retry missing slots; MLS buffers application messages of the current epoch that arrive early; a commit not yet visible is simply waited for | Yes |
| F2 | **Admin offline** | Messages keep flowing; proposals queue; membership frozen; successor after `T_successor` (§B5.4) | Yes |
| F3 | **Duplicated commit** (same commit delivered twice) | Second copy ignored (same epoch, same content) | Yes |
| F4 | **Replayed or older commit** | Rejected by the epoch rule (§B5.2 r1–r2) | Yes |
| F5 | **Rollback**: storage node serves an older control record | Ignored (§B5.2 r3); member keeps polling | Yes |
| F6 | **Out-of-order application messages** within an epoch | Decrypted via MLS generation numbers; up to 100 skipped keys kept per sender; `prev` chain reports real gaps | Yes |
| F7 | **Message from epoch `e` arriving after `e + 1`** | Decrypted if inside the retention window (previous epoch kept for 24 h or until all members moved, whichever is shorter), else shown as "could not decrypt" | Yes |
| F8 | **Restart during the move to a new generation** | Resumes from the persisted state (§B5.3 table); no duplicate outbox, no lost announcement | Yes |
| F9 | **Admin restarts mid-commit** | Resumes the persisted publication (§B5.1, "Publishing"): the same commit and the same ciphertexts, never a different one for the same epoch | Yes |
| F10 | **Member offline during a removal** | Catches up from `C_g` within the 30-day grace period; afterwards needs a re-invite | Yes (shortened grace) |
| F11 | **Member device lost** | Rejoins as a new member with a new `CIK` (shown as a new, unverified identity); the admin removes the old leaf | Partly |
| F12 | **Admin device lost** | Successor takeover (§B5.4); without a successor, membership frozen | Yes |
| F13 | **Concurrent proposals** from two members | The admin commits them in one order; all members end in the same epoch | Yes |
| F14 | **Fork**: admin returns after a takeover | Members on the new generation ignore the old one; a member on the fork detects it and is re-added as a new identity (§B5.4) | Yes |
| F15 | **Removed member keeps writing** its old outbox | Ignored: not a member of epoch `e + 1`, and the old outbox is no longer watched | Yes |
| F16 | **Storage node drops writes** | Detected via `prev` chain, `logHash` and log counts; never silently accepted. A lost outbox write is re-sent by its writer; a lost control-log write is only waited for (repair by the admin: before v2.0) | Partly |
| F17 | **Oversized MLS message** (Welcome for a large group) | Split across subkeys and reassembled (§B3, chunking) | Yes |
| F18 | **Malformed data** from a member or node: invites, heads, commits, messages, chunk headers | Rejected without crashing or changing state (fuzz tests of every parser) | Yes |
| F19 | **Diverging histories**: the admin rewrites a log position after some members read it | Members compare `ctl` in messages (§B5.2 r6); a mismatch stops new commits and shows a warning | No: test in the implementation |

## B13. Proof of concept

**Status: done** in `native/mls_poc` (OpenMLS 0.9.2), except phone
timings and memory use.
Every item below passes except the last measurement: timings so far are
from an x86-64 desktop (all operations under 3 ms) because the crate has no
Android build yet. The findings are folded into §B3, §B4, §B5.1, §B5.2,
§B5.3, §B5.4, §B7 and §B12; details and numbers are in
`native/mls_poc/README.md`.

Goal: prove that OpenMLS, FFI and admin-sequenced commits work before any
app code migrates.

Scope:

* A Rust crate in the repo with OpenMLS, ciphersuite 0x0003, an FFI bridge,
  and an in-memory mock DHT (records, subkeys, owners, delay, loss,
  reordering, rollback).
* Minimal scenario: two independent identities; create a group; the second
  member joins via KeyPackage/Welcome; exchange encrypted messages; epoch
  rotation (Update); removal, then a check that the removed member cannot
  decrypt anything later; persisting and restoring MLS state after a
  restart.
* A Flutter test that calls the same scenario through FFI.
* The failure scenarios F1–F18 where the mock allows.
* Measurements: sizes of KeyPackage, Welcome, commit and application
  messages against the 32 KiB subkey limit; time per operation on a
  physical Android phone (OpenMLS initialisation, join, epoch change,
  restoring state after a restart) and memory use.

Acceptance: every item above passes, and nothing in the app's `lib/` changes.

## B14. Order of work

1. ✅ Threat model and protocol direction approved (this revision).
2. ✅ PoC (§B13), including the failure tests (§B12). Open: phone timings
   (needs an Android build of the crate).
3. ✅ Review the PoC; adjust this document where it proved wrong (this
   revision). Proposals go into commits by value (§B5.1). Open: crypto
   provider (§B7).
4. Group control record, join flow, removal with generation move.
5. E2EE messages, encrypted media, padding.
6. Per-conversation identities by default; global profile and presence
   opt-in.
7. v1 read-only mode and the move to v2.
8. Later items from §B0.
