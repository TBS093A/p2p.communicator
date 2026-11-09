//! On-device measurements (docs/PROTOCOL.md B13): the minimal scenario run
//! repeatedly, with the first (cold) run reported separately from the
//! median of the rest, and the process memory before and after. Called
//! through FFI by the Android bench app (native/mls_poc/android_bench).

use serde::Serialize;

use crate::scenario::{run_minimal, Report};

#[derive(Debug, Default, Serialize)]
pub struct Bench {
    pub ok: bool,
    pub runs: usize,
    pub arch: &'static str,
    pub os: &'static str,
    /// Milliseconds per operation in the first run (cold caches, first use
    /// of OpenMLS in the process).
    pub first_ms: Vec<(String, f64)>,
    /// Median and maximum per operation over the remaining runs.
    pub median_ms: Vec<(String, f64)>,
    pub max_ms: Vec<(String, f64)>,
    /// Resident memory (VmRSS) before the first run and after the last,
    /// and the peak (VmHWM), in KiB; 0 where /proc is not available.
    pub rss_kib_before: u64,
    pub rss_kib_after: u64,
    pub rss_kib_peak: u64,
    /// The first run's report: steps, sizes, DHT writes.
    pub first: Report,
}

/// Runs the scenario `runs` times (at least 2).
pub fn run(runs: usize) -> Bench {
    let runs = runs.max(2);
    let rss_kib_before = proc_status_kib("VmRSS");
    let reports: Vec<Report> = (0..runs).map(|_| run_minimal()).collect();
    let rss_kib_after = proc_status_kib("VmRSS");
    let ok = reports.iter().all(|r| r.ok);
    let mut first = reports.into_iter();
    let first_report = first.next().expect("runs >= 2");
    let rest: Vec<Report> = first.collect();

    let mut median_ms = vec![];
    let mut max_ms = vec![];
    for (name, _) in &first_report.timings_ms {
        let mut v: Vec<f64> = rest
            .iter()
            .filter_map(|r| r.timings_ms.iter().find(|(n, _)| n == name))
            .map(|(_, t)| *t)
            .collect();
        v.sort_by(|a, b| a.total_cmp(b));
        if v.is_empty() {
            continue;
        }
        median_ms.push((name.clone(), v[v.len() / 2]));
        max_ms.push((name.clone(), v[v.len() - 1]));
    }

    Bench {
        ok,
        runs,
        arch: std::env::consts::ARCH,
        os: std::env::consts::OS,
        first_ms: first_report.timings_ms.clone(),
        median_ms,
        max_ms,
        rss_kib_before,
        rss_kib_after,
        rss_kib_peak: proc_status_kib("VmHWM"),
        first: first_report,
    }
}

/// A "Name:   1234 kB" line of /proc/self/status (Linux and Android).
fn proc_status_kib(field: &str) -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with(field) && l[field.len()..].starts_with(':'))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|n| n.parse().ok())
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    #[test]
    fn bench_runs_and_reports() {
        let b = super::run(3);
        assert!(b.ok, "{:#?}", b.first.steps);
        assert_eq!(b.runs, 3);
        assert!(!b.median_ms.is_empty());
        assert_eq!(b.median_ms.len(), b.first_ms.len());
        if cfg!(target_os = "linux") {
            assert!(b.rss_kib_peak > 0, "VmHWM not read");
        }
    }
}
