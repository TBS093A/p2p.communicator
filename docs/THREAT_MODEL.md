# Threat model

Status: **draft for review**, 9 Nov 2026. Describes the protocol on `main`
after PRs #12 (outbox sync gaps) and #13 (signed DM invites, temp file wipe).
The wire format and records are specified in [PROTOCOL.md](PROTOCOL.md).

## 1. Goal

p2p.communicator is meant to be an **anonymous, maximally private
messenger**, not just a messenger without a central server. Concretely:

* other participants cannot easily link your identities across
  conversations,
* nobody in the network (and no participant) learns your IP address from
  using the app,
* taking today's keys does not reveal earlier conversations, and a removed
  member cannot read what is said after removal.

Version 1 (what is on `main` today) does **not** meet this goal. This
document names the target, the gaps, and what is out of scope even for the
target. Every claim below is either "holds in v1", "partly", or "target
only", and says so.

## 2. Assets

| Asset | Where it lives |
| --- | --- |
| Message content (text, media, voice) | Outbox records, blob records, local cache |
| Who talks to whom (social graph) | Rosters, outbox heads, global profile pointers |
| Link between your conversations | Global profile key, identity key, timing |
| Activity metadata (when, how much) | Outbox counters, heartbeat `seen`, DHT write timing |
| Your IP address / location | Veilid transport |
| Membership capability (who may read / write a room) | Invite, roster writer key, record keys |
| Long-term secrets: identity key, room secrets | PIN vault on the phone |
| Existence of private rooms | PIN vault slots (decoys, padding) |
| History on the phone | Encrypted local cache, media cache |

## 3. Adversaries

| ID | Adversary | Capabilities | In scope |
| --- | --- | --- | --- |
| A1 | **Local network observer** (Wi-Fi, ISP, mobile operator) | Sees your traffic to Veilid peers: timing, volume, peer IPs | Yes |
| A2 | **Veilid node operator(s)**, incl. many nodes (Sybil) | Stores and routes DHT records, sees requests that reach it, can drop or delay data, can run many nodes | Yes |
| A3 | **Outsider with a leaked capability** | Holds an invite string or a record key (screenshot, forwarded QR, backup) but was never meant to be a member | Yes |
| A4 | **Malicious current member** | Everything a member legitimately has, plus arbitrary writes the protocol lets members make | Yes |
| A5 | **Removed member** | Was a member, kept everything they saw and every key they held | Yes |
| A6 | **Contact in several of your conversations** | Member of more than one of your rooms; wants to link your identities | Yes |
| A7 | **Thief of a locked phone** | Physical access, phone locked, app locked; can copy app files (rooted/forensic) | Yes |
| A8 | **Coercion** | Can force you to unlock the app with a PIN | Partly (deniability of private rooms) |
| A9 | **Unlocked phone or malware on the phone** | Reads memory and screen while the app is open | **No** (see §7) |
| A10 | **Global passive observer** | Sees all internet traffic, correlates timing end to end | **No** for now (see §7) |
| A11 | **Supply chain / build** | Tampered dependency, CI secret, release APK | Partly (CI checks, signing); not analysed here |

## 4. Trust boundaries

```
 ┌──────────── your phone ─────────────┐        ┌──── Veilid network ────┐
 │ UI ── AppSession / RoomSession ──┐  │        │ routing nodes          │
 │                                  │  │ safety │ DHT storage nodes      │
 │ PIN vault (Argon2 + Keystore     │  ├─routes─┤ (see ciphertext of     │
 │ pepper) ── encrypted cache/media │  │        │  records unless they   │
 │                                  │  │        │  hold the record key)  │
 └──────────────────────────────────┘  │        └────────────────────────┘
                                       │
            other members' phones ◄────┘  (only via DHT records, never direct)
```

* **Trusted:** the phone while the app is unlocked, the Veilid crypto
  (VLD0: Ed25519, X25519, XChaCha20-Poly1305, BLAKE3, Argon2), the Android
  Keystore, the OS RNG.
* **Untrusted:** every network node, every other member (members are
  trusted only to read what they were invited to), anyone who sees an
  invite.
* **The DHT record key is a capability.** In Veilid a record key carries its
  encryption secret, so whoever holds it can read the record. In v1 there is
  no second layer: whoever can read a record reads the plaintext JSON.

## 5. Security goals and status

| ID | Goal | v1 status | Notes |
| --- | --- | --- | --- |
| G1 | Network nodes (A2) cannot read content | **Holds** | Records are encrypted by Veilid with a per-record secret that travels only in invites/rosters. |
| G2 | Content is end-to-end encrypted by the app, independent of DHT encryption | **Target only** | v1 relies solely on Veilid record encryption. A leaked record key = plaintext. |
| G3 | Someone holding an invite can be refused or revoked | **Does not hold** | The invite *is* membership (roster key + writer key). |
| G4 | Only authorised members can change membership | **Does not hold** | Every member holds the roster writer key and can rewrite any slot, incl. room name and other members' entries. |
| G5 | A removed member cannot read future messages | **Does not hold** | They keep the roster key and every outbox key; there is no removal at all. |
| G6 | Message sender is authenticated | **Partly** | An outbox is writable only by its owner key, so a message in outbox X was written by X's holder. But the roster mapping "slot → outbox → name" is writable by every member (G4), so a member can relabel or replace entries. |
| G7 | DM invite sender is authenticated | **Holds** (after #13) | Signed with the identity key published in the sender's profile record; recipient-bound. |
| G8 | Your conversations cannot be linked to each other by their members (A6) | **Partly** | Private rooms: separate random keys, no profile pointer. DMs and groups: same `p` (global profile key) everywhere, by design. |
| G9 | Your IP is hidden from nodes reading/writing your records | **Partly, to verify** | The default routing context uses safety routes for DHT operations. Not yet verified for watches, and not tested against an adversary. |
| G10 | Forward secrecy: today's keys do not open yesterday's messages | **Does not hold** | Room keys are static for the room's lifetime; every past message stays in the DHT ring (last 200 per member) readable with the same key. |
| G11 | Post-compromise security: the room heals after a key leak | **Does not hold** | No key rotation. |
| G12 | Presence/activity is not published | **Partly** | Groups/DMs publish `seen` every 60 s unless "invisible"; going invisible does not erase the last value. Private rooms publish none. Outbox counters and write timing leak activity to members everywhere. |
| G13 | A locked phone does not reveal content or which private rooms exist (A7) | **Holds, mostly** | Argon2 + Keystore pepper; padded, equal-size slots with decoys; attempt throttling. Temp plaintext wiped on next start (#13). |
| G14 | Deniability of private rooms under coercion (A8) | **Partly** | No list of private rooms exists; the app PIN does not reveal them. Not a plausible-deniability design against forensic analysis of usage. |
| G15 | Messages are not lost or reordered undetectably by the network | **Partly** | Gaps are retried (#12); a node can still withhold data; no end-to-end acknowledgement or hash chain. |
| G16 | Moving to a new phone does not leak data | **Holds, mostly** | HPKE to a one-time key shown as QR, AEAD per entry. Two phones holding the same writer keys afterwards is undefined (see §6 S14). |

## 6. Attack scenarios (v1)

| # | Scenario | Adversary | v1 outcome | Target mitigation |
| --- | --- | --- | --- | --- |
| S1 | Invite QR is photographed or forwarded | A3 | Full member forever: reads everything, can write the roster | One-time join tokens approved by an admin; no write capability in invites (PROTOCOL §B4) |
| S2 | Member rewrites roster: renames the room, overwrites another member's slot with their own outbox, or blanks slots | A4 | Works; others see a different member list | Roster owned by admins (single-writer or SMPL), signed membership commits |
| S3 | Member impersonates another member by copying their name/avatar into their own head | A4 | Works visually; outbox key differs, but the UI shows names | Per-conversation identity keys, verified fingerprints, signed profile in membership |
| S4 | Removed person keeps reading | A5 | There is no removal; they read every future message | Key epochs: removal = new epoch whose keys they never get (PROTOCOL §B5) |
| S5 | Old phone backup or a leaked room secret years later | A3/A5 | Last 200 messages per member in the DHT readable | Forward secrecy (ratchet/MLS) + DHT content only under per-epoch app keys |
| S6 | Contact in two of your groups links them | A6 | Trivial: same global profile key `p` | Per-conversation identity by default; global profile opt-in |
| S7 | Contact tracks when you are online | A6 | `seen` heartbeat every 60 s; outbox write timing | No heartbeat by default; presence only per conversation, opt-in; batching/jitter |
| S8 | Forged DM invite claiming to be from a friend | A4 | Fixed in #13 (signature check) | Kept; moves to per-conversation identities |
| S9 | Node withholds or rolls back a record value | A2 | Receiver waits/misses messages; sees stale data silently | Per-sender hash chain + gap detection shown in UI |
| S10 | Malformed or huge data in a record a member controls | A4 | Parsers skip unknown types; sizes bounded by DHT limits | Fuzz tests of all parsers (PROTOCOL §B9) |
| S11 | Replay of an old message/commit into a slot | A4 | Seq check ignores older seq in a slot; roster writes can be replayed | Signed, epoch-bound messages; commits with monotonic epoch numbers |
| S12 | Network observer learns you use the app and when | A1 | Yes: Veilid traffic is recognisable, timing visible | Out of scope for now beyond Veilid's own routing (§7) |
| S13 | Locked-phone forensic copy | A7 | Needs Keystore pepper + Argon2 per guess; slots padded | Kept; add memory hygiene where feasible |
| S14 | Old phone kept after migration keeps writing | — | Two writers on the same records; conflicts undefined | Device keys; migration revokes the old device |
| S15 | Two members join at once and race for a roster slot | A4/benign | Handled by write-then-verify; a malicious member can still overwrite | Admin-sequenced membership |

## 7. Explicitly out of scope (for now)

* **Global passive adversary (A10).** End-to-end timing correlation across
  the internet is not defended against. Veilid safety/private routes raise
  the cost but are not a mixnet with cover traffic. We do not claim
  anonymity against such an observer.
* **Unlocked phone or malware (A9).** Anything on screen or in memory while
  the app is open is exposed. We only try to keep the plaintext footprint on
  disk small.
* **Hiding that you use the app** from your network or from someone holding
  your phone.
* **Denial of service** by network nodes (dropping data). Detecting it is in
  scope (S9), preventing it is not.
* **Side channels** of the Veilid implementation and the Flutter runtime.

## 8. Assumptions

1. Veilid's VLD0 primitives and its record encryption are sound, and its
   safety routes hide the requesting node from the storing node as
   documented.
2. Android Keystore keeps the vault pepper non-exportable.
3. Users compare something out of band (QR in person, or a fingerprint) the
   first time; without that, an active attacker in the invite channel can
   always insert themselves.
4. Members' phones are honest about what they store for themselves; a member
   may still leak anything they can read (no protocol prevents screenshots).

## 9. Decisions taken (9 Nov 2026)

| Area | Decision |
| --- | --- |
| Identity | Separate key set per conversation, by default |
| Global profile | Optional, explicitly enabled per conversation |
| Transport | Veilid with privacy-preserving (safety/private) routes |
| Encryption | App-level E2EE, independent of DHT record encryption |
| Groups | Admin keys separate from member keys |
| Removing a member | New key epoch; the removed member loses access to future messages |
| History | Forward secrecy and post-compromise security |
| Metadata | Minimise identifiers, activity timing and links |
| Devices | Eventually multi-device with separate device keys |

## 10. Open questions

1. **MLS or a simpler sender-keys scheme?** PROTOCOL §B6 recommends MLS
   (RFC 9420, via OpenMLS in Rust). That needs one ordered commit log per
   group, which the DHT does not give for free.
2. **Who orders membership changes?** A single admin as sequencer is simple
   but means the group cannot change membership while that admin is offline.
3. **Should removal also move the room to fresh DHT records**, so a removed
   member cannot even see ciphertext volume and timing? It costs a full
   re-invite of remaining members.
4. **Presence:** drop it entirely, keep it per conversation opt-in, or keep a
   coarse "active today" only?
5. **Migration of v1 rooms:** archive read-only and recreate as v2 (honest),
   or upgrade in place (cheaper, but the v1 secrets stay valid for whoever
   ever held them)? PROTOCOL §B10 proposes the former.
