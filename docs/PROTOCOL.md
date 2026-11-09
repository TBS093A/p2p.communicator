# Protocol

Status: **draft for review**, 9 Nov 2026.

* **Part A** documents protocol v1 as implemented on `main` (plus PRs #12
  and #13, which are about to merge). It is descriptive: if code and this
  text disagree, the code wins and this text is a bug.
* **Part B** proposes protocol v2, which follows from the decisions in
  [THREAT_MODEL.md §9](THREAT_MODEL.md#9-decisions-taken-9-nov-2026). Nothing
  in part B is implemented. **Approve or change it before any roster work
  starts**, because v2 rooms cannot be read by v1 apps and v1 rooms need a
  migration.

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

# Part B: protocol v2 (proposal)

## B1. Principles

1. **Two layers.** Everything the app puts in the DHT is encrypted and
   authenticated by the app (E2EE) first. Veilid record encryption stays as
   an outer layer. A leaked record key then reveals only ciphertext and
   sizes.
2. **No capability is shared by everyone.** Each writer has their own key.
   Membership changes are signed by an admin and ordered.
3. **Membership is a sequence of epochs.** Each change (add, remove,
   periodic update) starts a new epoch with fresh keys. A removed member
   never gets the new epoch's keys.
4. **No home-grown crypto protocol.** Group key agreement comes from a
   standard (MLS, RFC 9420) and an audited implementation.
5. **One identity per conversation by default.** Linking a conversation to
   your global profile is an explicit, per-conversation choice.
6. **Minimal metadata.** No names or profile pointers in clear, no presence
   heartbeat by default, padded message sizes.

## B2. Keys

| Key | Scope | Purpose |
| --- | --- | --- |
| Conversation identity key `CIK` (Ed25519) | One per conversation per user | Your identity inside that conversation: MLS credential, signs your messages. Random, so conversations are unlinkable. |
| Device key `DK` (later) | One per device | Multi-device: each device is its own MLS leaf under the same `CIK`. Not in v2.0. |
| Group admin key `GAK` (Ed25519) | One per group | Owns the group control record; signs commits. Shared among admins in v2.0 (see B5). |
| Outbox owner key | One per member per conversation | Writes that member's outbox record. |
| MLS epoch secrets | Per group, per epoch | Encrypt application messages; derived by MLS. Previous epochs' secrets are deleted (forward secrecy). |
| Media key | Per file | AEAD key for a blob; travels inside the E2EE message. |
| Global identity `GIK` (optional) | Per user | Only if the user enables a global profile; never required. |

## B3. Records

| Record | Schema / owner | Content |
| --- | --- | --- |
| **Group control** | `DFLT`, owner `GAK` | Subkey 0: header `{v: 2, groupId, epoch, commitCount}` (MLS-protected where possible). Subkeys 1..N: ring of MLS commits and Welcome pointers, each signed by an admin. Only admins can write. |
| **Member outbox** | `DFLT`, owner = member's outbox key | Subkey 0: head `{count}` only, padded. Subkeys 1..ring: MLS `PrivateMessage`s. |
| **Join rendezvous** | `SMPL`: owner = inviter, 1 member subkey whose key pair is in the invite | The joiner writes one MLS `KeyPackage` (sealed to the inviter's `CIK`). One-time: after use the admin ignores the slot. |
| **Blob** | `DFLT`, random owner | Chunks of the **AEAD-encrypted** file. |
| **Global profile** (optional) | `DFLT`, owner `GIK` | As in v1, without `seen` by default. |

The roster as a separate writable list goes away: **the MLS group state is
the member list**, and every member derives it from the commit log.

SMPL schemas fix their member list at creation. That suits "one rendezvous
record per invite", and "fresh records per epoch" if we choose that
(open question 3 in the threat model).

## B4. Joining

1. The admin creates an invite:
   `"p2pc2." + base64url({rendezvousKey, rendezvousWriter, adminCIK, groupHint?, expiresAt})`.
   The invite carries **no** read access to the group and no write access
   except one subkey in the rendezvous record.
2. The joiner generates a `CIK`, creates an MLS `KeyPackage`, seals it to
   `adminCIK` and writes it to the rendezvous slot.
3. The admin's app shows the join request (name chosen by the joiner,
   `CIK` fingerprint) and the admin approves it.
4. The admin publishes an MLS `Add` commit (new epoch) to the control record
   and a `Welcome` sealed to the joiner's KeyPackage. The Welcome carries the
   control record key and the members' outbox keys.
5. The joiner creates its outbox and announces it in an MLS-protected
   message.

A leaked invite lets someone *request* to join; it no longer *is*
membership. An expired or already used invite is ignored.

**DMs** use the same mechanism with two members; a DM started from a group
is a DM invite (as in A5) sealed to the peer's `CIK` *in that group* and
signed with mine, so it does not reveal global identities either.

## B5. Membership changes and epochs

* **Add / remove / update** are MLS proposals. Any member may propose, as
  an MLS-protected message in their outbox. Only an admin **commits** them,
  writing to the control record. The commit log gives the total order that
  MLS needs; the admin is the sequencer.
* **Removal:** the admin commits `Remove`; the new epoch's secrets are not
  derivable by the removed member. Their outbox is dropped from the member
  set and later messages in it are ignored.
* **Periodic update:** every member sends an `Update` (fresh leaf key) at
  least every N days or M messages, giving post-compromise security.
* **Admins:** in v2.0 all admins share `GAK`, so admin rights are again a
  shared capability, limited to admins. Revoking an admin = new control
  record + new `GAK` for the remaining admins (one commit pointing to it).
  Multi-admin without a shared key needs a different sequencing scheme;
  not in v2.0.
* **Admin offline:** proposals queue in outboxes; membership cannot change
  until an admin is back. Messages keep flowing.

## B6. Why MLS (and not Sender Keys or a custom ratchet)

| | MLS (RFC 9420) | Signal Sender Keys | Custom |
| --- | --- | --- | --- |
| Forward secrecy | Yes (per epoch + per message) | Per sender chain | ? |
| Post-compromise security | Yes (Update/Commit) | Weak: needs re-keying of everyone | ? |
| Removal cost | O(log n) | O(n) pairwise re-distribution | ? |
| Standard, audited libraries | OpenMLS (Rust), RFC, formal analyses | libsignal (used by Signal) | No |
| Needs ordered commits | **Yes**, provided here by the admin-written control record | No | ? |
| Fits our stack | Rust, like veilid-core: one more FFI crate | Possible | — |

**Recommendation:** MLS via OpenMLS, ciphersuite
`MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519` (same curve family as
Veilid). Integration through `flutter_rust_bridge` or the same mechanism
`veilid-flutter` uses.

## B7. Application messages

Inside an MLS `PrivateMessage` (authenticated by the sender's leaf, so
the author is proven by crypto, not by which outbox it came from):

```json
{"v": 2, "id": "<random 128-bit>", "seq": 17, "ts": 1731150000000,
 "t": "text", "text": "...",
 "m": {"mime", "size", "hash", "rec": [...], "key": "<media AEAD key>", ...},
 "prev": "<hash of my previous message>"}
```

* `prev` chains each sender's messages, so a withheld or swapped message is
  detected (THREAT_MODEL S9).
* The plaintext is padded to the next of 256 / 1024 / 4096 bytes before
  encryption.
* Profile changes (name, avatar, color) are messages of type `profile`, not
  fields in the outbox head.

## B8. Media

The file is encrypted with a fresh random key (XChaCha20-Poly1305,
chunk-wise with the chunk index as the nonce context) before it is split
into blob records. The key and the plaintext hash travel only inside the
E2EE message. A leaked blob record key reveals nothing but the size. Moving
large media off the DHT (direct P2P transfer) is a separate, later change.

## B9. Metadata

| Leak in v1 | v2 |
| --- | --- |
| Names and profile pointers in roster and heads | Only inside E2EE messages |
| `seen` heartbeat every 60 s | Off by default; optional per conversation, coarse |
| Exact message sizes | Padded buckets |
| Same global profile in every DM/group | Per-conversation `CIK`; global profile opt-in |
| Write timing per message | Unchanged in v2.0. Batching/jitter is a later option, since it costs latency |
| Outbox counters visible to anyone with the record key | Visible to members only, but still there; fresh records per epoch would hide them from removed members |

## B10. Migration from v1

v1 rooms cannot be made v2-safe in place: their roster writer and record
keys are already in everyone's hands, so nothing can be revoked. Proposal:

1. A v2 app still **opens v1 rooms read-only**, marked "old protocol".
2. Any member can "upgrade" a v1 room: they create a v2 group (becoming its
   admin) and post a v1 message with a v2 invite. Each member joins
   explicitly; the admin approves.
3. Once upgraded, the app stops writing to the v1 room.
4. v1 invites (`p2pc1.`) can still be scanned but only open read-only.

Private rooms follow the same path; their password slot then points to the
v2 group.

## B11. Security test plan (step 3 of the roadmap)

Protocol tests that run without the public network, against a mocked DHT
(an in-memory record store with configurable delay, loss and reordering):

| Test | Expect |
| --- | --- |
| Impersonation: member writes a message claiming another leaf | Rejected by MLS |
| Replay of an old commit or message | Rejected (epoch / generation check) |
| Concurrent proposals from two members | Both committed in a single order; all members agree on the epoch |
| Removal | Removed member cannot decrypt anything from the next epoch |
| Withheld message (node drops one) | Gap detected by `prev` chain, shown, retried |
| Lost connectivity during a commit | Member catches up from the commit log |
| Join with an expired / reused invite | Ignored |
| Fuzzing every parser (invite, messages, commits, heads) | No crash, no state change |
| Two devices with the same keys (S14) | Defined behavior, not silent conflict |

## B12. Order of work

1. Approve this document (and the threat model's open questions).
2. Spike: OpenMLS through FFI on Android, a two-member group through a
   mocked DHT.
3. Mocked-DHT test harness (B11).
4. Group control record + join flow + removal.
5. E2EE messages and encrypted media.
6. Per-conversation identities by default; global profile opt-in.
7. v1 → v2 migration.
8. Multi-device (device keys).
