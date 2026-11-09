//! docs/PROTOCOL.md B13 minimal scenario.

#[test]
fn minimal_scenario_passes() {
    let r = mls_poc::scenario::run_minimal();
    for s in &r.steps {
        println!(
            "[{}] {} {}",
            if s.ok { "ok" } else { "FAIL" },
            s.name,
            s.detail
        );
    }
    for (n, s) in &r.sizes {
        println!("size {n}: {s} B");
    }
    for (n, t) in &r.timings_ms {
        println!("time {n}: {t:.2} ms");
    }
    assert!(r.ok, "{:#?}", r.steps);
}
