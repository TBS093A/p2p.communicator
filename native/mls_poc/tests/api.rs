//! The app's API (src/api.rs) driven exactly as the Dart host will drive
//! it: only JSON round requests and replies, the DHT on the host's side.

use mls_poc::api::{unhex, RoundIn, RoundOut, Session};
use mls_poc::dht::{Dht, MockDht};
use mls_poc::wire;
use serde_json::{json, Value};

/// The host loop (docs/V2_PLAN.md, option C), as the Dart side implements
/// it: dry rounds until the reads settle, then one committed round, then
/// its writes.
struct Host {
    dht: MockDht,
}

impl Host {
    fn round(&mut self, s: &mut Session, op: Value) -> RoundOut {
        let mut known: Vec<(String, u32)> = vec![];
        let records: Vec<Value> = (0..3)
            .map(|_| {
                let (r, o) = Dht::create(&mut self.dht).unwrap();
                json!({"record": r, "owner": wire::hex(&o)})
            })
            .collect();
        let (rv, owner, slot) = self.dht.create_rendezvous(1..=4).unwrap();
        let rendezvous = vec![json!({
            "record": rv, "owner": wire::hex(&owner), "slot": wire::hex(&slot),
        })];
        let request = |dht: &MockDht, known: &[(String, u32)], commit: bool| -> RoundIn {
            let values: Vec<Value> = known
                .iter()
                .map(|(r, k)| {
                    let v = MockDht::get(dht, r, *k).unwrap().map(|b| wire::hex(&b));
                    json!({"record": r, "subkey": k, "value": v})
                })
                .collect();
            let mut req = op.clone();
            let obj = req.as_object_mut().unwrap();
            obj.insert("now".into(), json!(dht.now));
            obj.insert("values".into(), json!(values));
            obj.insert("record_pool".into(), json!(records));
            obj.insert("rendezvous_pool".into(), json!(rendezvous));
            obj.insert("commit".into(), json!(commit));
            serde_json::from_value(req).expect("valid request")
        };
        for _ in 0..32 {
            let out = s.round(request(&self.dht, &known, false));
            assert!(out.writes.is_empty(), "a dry round never writes");
            let new: Vec<_> = out
                .needs
                .into_iter()
                .filter(|k| !known.contains(k))
                .collect();
            if new.is_empty() {
                break;
            }
            known.extend(new);
        }
        let out = s.round(request(&self.dht, &known, true));
        // The host saves the session here (before writing), then writes.
        let saved = s.save();
        assert!(Session::restore(&saved).is_ok());
        for w in &out.writes {
            self.dht
                .set(
                    &w.record,
                    w.subkey,
                    &unhex(&w.value).unwrap(),
                    &unhex(&w.writer).unwrap(),
                )
                .unwrap();
        }
        out
    }

    fn ok(&mut self, s: &mut Session, op: Value) -> Value {
        let out = self.round(s, op);
        assert!(out.ok, "{:?}", out.error);
        out.result
    }
}

fn texts(s: &Session) -> Vec<String> {
    s.info(0)["inbox"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["text"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn a_conversation_through_json_rounds_only() {
    let mut host = Host {
        dht: MockDht::new(),
    };
    let mut alice = Session::new("alice");
    let mut bob = Session::new("bob");

    host.ok(&mut alice, json!({"op": "create_group"}));
    assert_eq!(alice.info(0)["is_admin"], true);

    let invite = host.ok(&mut alice, json!({"op": "create_invite"}));
    let invite = invite.as_str().unwrap().to_string();
    assert!(invite.starts_with("p2pc2."));
    // The joiner compared the admin's key out of band (§B4).
    let admin = alice.info(0)["cik"].as_str().unwrap().to_string();
    host.ok(
        &mut bob,
        json!({"op": "request_join", "invite": invite, "verified_admin": admin}),
    );
    let rendezvous: Value = serde_json::from_str(invite.strip_prefix("p2pc2.").unwrap()).unwrap();
    host.ok(
        &mut alice,
        json!({"op": "stage_add", "rendezvous": rendezvous["rendezvous"]}),
    );
    host.ok(&mut alice, json!({"op": "publish_pending"}));
    let joined = host.ok(&mut bob, json!({"op": "complete_join", "invite": invite}));
    assert_eq!(joined, true);
    for _ in 0..3 {
        host.ok(&mut alice, json!({"op": "sync"}));
        host.ok(&mut bob, json!({"op": "sync"}));
    }
    assert_eq!(alice.info(0)["members"].as_array().unwrap().len(), 2);
    assert_eq!(bob.info(0)["epoch"], alice.info(0)["epoch"]);

    host.ok(&mut alice, json!({"op": "send_text", "text": "cześć Bob"}));
    host.ok(&mut bob, json!({"op": "send_text", "text": "hej Alice"}));
    for _ in 0..2 {
        host.ok(&mut alice, json!({"op": "sync"}));
        host.ok(&mut bob, json!({"op": "sync"}));
    }
    assert_eq!(texts(&bob).iter().filter(|t| *t == "cześć Bob").count(), 1);
    assert!(texts(&alice).contains(&"hej Alice".to_string()));

    // Restart from the saved state: still in the group, still reading.
    bob = Session::restore(&bob.save()).unwrap();
    host.ok(
        &mut alice,
        json!({"op": "send_text", "text": "po restarcie"}),
    );
    host.ok(&mut bob, json!({"op": "sync"}));
    assert!(texts(&bob).contains(&"po restarcie".to_string()));
    // `since` returns only the new part of the inbox.
    let n = bob.info(0)["inbox_len"].as_u64().unwrap() as usize;
    assert_eq!(bob.info(n - 1)["inbox"].as_array().unwrap().len(), 1);
}

#[test]
fn bad_requests_are_errors_not_panics() {
    let mut s = Session::new("x");
    let out = s.round(
        serde_json::from_value(json!({
            "op": "sync",
            "values": [{"record": "r", "subkey": 0, "value": "zz"}],
        }))
        .unwrap(),
    );
    assert!(!out.ok);
    let out = s.round(
        serde_json::from_value(json!({
            "op": "request_join", "invite": "garbage", "verified_admin": "00",
            "commit": true,
        }))
        .unwrap(),
    );
    assert!(!out.ok);
    assert!(out.error.unwrap().contains("invite"));
    assert!(Session::restore(b"not a state").is_err());
}
