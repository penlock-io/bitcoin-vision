//! The scan as a caller drives it: started, run on some thread, followed
//! through its record. These pin the protocol, never what the model read.
#![cfg(feature = "bundled-models")]

use std::time::Duration;

use bitcoin_vision_core::scan::{Cursor, Delta, Outcome, Snapshot};
use bitcoin_vision_words::progress::{Phase, RegionState};
use bitcoin_vision_words::{Found, Layout, ScanOptions, Scanner, Words};

fn photo() -> image::RgbImage {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/photos/handwritten.png");
    bitcoin_vision_core::decode_image(&std::fs::read(path).unwrap(), None).unwrap()
}

fn page() -> ScanOptions {
    ScanOptions {
        layout: Layout::Page,
        ..ScanOptions::default()
    }
}

#[test]
fn a_scan_followed_from_another_thread_misses_nothing_and_ends_once() {
    let scanner = Scanner::bundled().unwrap();
    let (scan, state) = scanner.start(photo(), ScanOptions::default());
    let (polled, outcome) = std::thread::scope(|scope| {
        let follower = scope.spawn(|| {
            let mut all = Vec::new();
            let mut cursor = Cursor::default();
            // A record that never ends fails here rather than hanging the suite.
            let deadline = std::time::Instant::now() + Duration::from_secs(120);
            loop {
                assert!(
                    std::time::Instant::now() < deadline,
                    "the scan never ended its record"
                );
                let (new, at) = state.wait(cursor, Duration::from_millis(20));
                cursor = at;
                let ended = new.iter().any(Delta::is_terminal);
                all.extend(new);
                if ended {
                    return all;
                }
            }
        });
        let outcome = scan.run();
        (follower.join().unwrap(), outcome)
    });

    let Outcome::Finished(result) = outcome else {
        panic!("the example page scans")
    };
    assert_eq!(result.found, Found::Page);
    assert_eq!(polled.iter().filter(|d| d.is_terminal()).count(), 1);
    assert!(polled.last().unwrap().is_terminal());
    assert!(matches!(
        polled[0],
        Delta::Work {
            phase: Phase::Preparing,
            ..
        }
    ));
    assert!(matches!(polled[1], Delta::Photo { .. }));

    let phases: Vec<Phase> = polled
        .iter()
        .filter_map(|d| match d {
            Delta::Work { phase, .. } => Some(*phase),
            _ => None,
        })
        .collect();
    let mut order = phases.clone();
    order.dedup();
    assert_eq!(
        order,
        [
            Phase::Preparing,
            Phase::Finding,
            Phase::Geometry,
            Phase::Reading,
            Phase::Checking,
            Phase::Packing
        ],
        "phases arrive in order, each once: {phases:?}"
    );

    // A reading is inspectable while the scan runs, not only in its result.
    let first_reading = polled
        .iter()
        .position(|d| matches!(d, Delta::Region { region, .. } if region.reading.is_some()))
        .expect("some region is recorded with its reading");
    assert!(first_reading < polled.len() - 1);

    let mut folded = Snapshot::<Words>::default();
    for delta in &polled {
        folded.apply(delta);
    }
    let snapshot = state.snapshot();
    assert_eq!(folded.cursor, snapshot.cursor);
    assert_eq!(folded.regions, snapshot.regions);
    assert_eq!(folded.retired, snapshot.retired);

    // Every region in the result was announced, and none is left mid-read.
    for region in &result.regions {
        let live = snapshot.regions.get(&region.id);
        assert!(
            live.is_some() || snapshot.retired.contains(&region.id),
            "result region {} was never recorded",
            region.id
        );
    }
    assert!(
        snapshot
            .regions
            .values()
            .all(|r| r.state != RegionState::Reading)
    );
    for region in snapshot.regions.values() {
        if region.state == RegionState::Read {
            let reading = region
                .reading
                .as_ref()
                .expect("a read region has its reading");
            assert!(
                reading.candidates.len() <= bitcoin_vision_words::progress::Reading::CANDIDATES
            );
        }
    }
}

#[test]
fn the_one_call_scan_is_the_machine_run_to_the_end() {
    let scanner = Scanner::bundled().unwrap();
    let (scan, _) = scanner.start(photo(), page());
    let Outcome::Finished(driven) = scan.run() else {
        panic!("the example page scans")
    };
    let called = scanner.scan_rgb(&photo(), page()).unwrap();
    let words = |r: &bitcoin_vision_words::ScanResult| {
        r.document()
            .observations
            .iter()
            .map(|w| (w.quad, w.selected))
            .collect::<Vec<_>>()
    };
    assert_eq!(words(&driven), words(&called));
    assert_eq!(driven.regions, called.regions);
}

#[test]
fn a_page_asked_to_be_a_sheet_fails_rather_than_being_read_as_a_page() {
    let scanner = Scanner::bundled().unwrap();
    let options = ScanOptions {
        layout: Layout::Sheet,
        ..ScanOptions::default()
    };
    let (scan, state) = scanner.start(photo(), options);
    assert!(matches!(scan.run(), Outcome::Failed(_)));
    let (deltas, _) = state.poll(Cursor::default());
    assert!(!deltas.iter().any(|d| matches!(d, Delta::Region { .. })));
    assert!(matches!(deltas.last(), Some(Delta::Failed(_))));
}

#[test]
fn a_scan_cancelled_before_it_runs_reads_nothing_and_ends_cancelled() {
    let scanner = Scanner::bundled().unwrap();
    let (scan, state) = scanner.start(photo(), page());
    state.cancel();
    assert!(matches!(scan.run(), Outcome::Cancelled));
    let (deltas, _) = state.poll(Cursor::default());
    assert!(matches!(deltas.last(), Some(Delta::Cancelled)));
    assert!(!deltas.iter().any(|d| matches!(d, Delta::Region { .. })));
}
