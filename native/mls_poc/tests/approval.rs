//! PROTOCOL §B4 step 4: the admin sees a join request (name and `CIK`)
//! and approves exactly that one.

mod common;

use common::*;
use mls_poc::member::Member;

#[test]
fn the_admin_approves_the_request_it_was_shown() {
    let (mut dht, mut g) = group(&["alice"]);
    let invite = g[0].create_invite(&mut dht).unwrap();
    let rv = invite.rendezvous.clone();
    let admin = invite.admin_cik.clone();
    assert!(
        g[0].peek_join(&mut dht, &rv).unwrap().is_none(),
        "no request yet"
    );

    let mut bob = Member::new("bob");
    bob.request_join_named(&mut dht, &invite, &admin, None, Some("  Bob  "))
        .unwrap();
    let shown = g[0].peek_join(&mut dht, &rv).unwrap().unwrap();
    assert_eq!(shown.cik, bob.st.cik);
    assert_eq!(shown.name, "Bob");

    // Someone else holding the same invite rewrites the request slot after
    // the admin looked: approving what was shown must not let them in.
    let mut eve = Member::new("eve");
    eve.request_join_named(&mut dht, &invite, &admin, None, Some("Bob"))
        .unwrap();
    let err = g[0]
        .stage_add_approved(&mut dht, &rv, &shown.cik)
        .unwrap_err();
    assert!(err.to_string().contains("changed"), "{err}");
    assert!(g[0].st.pending.is_none());

    // Bob writes again; now the request is his and the approval holds.
    bob.request_join_named(&mut dht, &invite, &admin, None, Some("Bob"))
        .unwrap();
    g[0].stage_add_approved(&mut dht, &rv, &shown.cik).unwrap();
    g[0].publish_pending(&mut dht).unwrap();
    assert!(bob.complete_join(&mut dht, &invite).unwrap());
    g.push(bob);
    sync_all(&mut dht, &mut g);
    assert_eq!(g[0].members().len(), 2);
    assert!(eve.group().is_none());
}

#[test]
fn a_long_name_is_refused_by_the_joiner() {
    let (mut dht, mut g) = group(&["alice"]);
    let invite = g[0].create_invite(&mut dht).unwrap();
    let admin = invite.admin_cik.clone();
    let mut bob = Member::new("bob");
    let long = "b".repeat(65);
    assert!(bob
        .request_join_named(&mut dht, &invite, &admin, None, Some(&long))
        .is_err());
}
